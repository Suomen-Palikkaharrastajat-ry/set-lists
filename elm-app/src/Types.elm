module Types exposing
    ( CatalogProvider(..)
    , ItemKind(..)
    , ListForm
    , ListRecord
    , ListStatus(..)
    , Service(..)
    , SetCatalog
    , SetItem
    , acceptCatalog
    , clearPhotoSlotFromItems
    , coverPhotoSlot
    , emptyForm
    , emptySetItem
    , fillTitleFromLookup
    , firstLookupCode
    , galleryPhotoSlots
    , itemHasTitle
    , itemHasValidCodes
    , itemKindFromString
    , itemKindToString
    , lookupCodeMatches
    , normalizePhotoSlots
    , photoSlots
    , savedPhotoFilename
    , serviceFromString
    , serviceName
    , serviceToString
    , setItemCodesText
    , setSavedPhoto
    , statusFromString
    , statusToString
    , validSetCode
    )

{-| Domain types for persisted table catalogs and their ordered rows.
-}

import Char
import Dict exposing (Dict)


type Service
    = Lego
    | Brickset
    | Bricklink
    | Rebrickable


type ItemKind
    = Set
    | AltBuild
    | Moc


type CatalogProvider
    = RebrickableCatalog
    | BricksetCatalog


type alias SetCatalog =
    { provider : CatalogProvider
    , code : String
    , name : String
    , year : Maybe Int
    , pieces : Maybe Int
    , imageUrl : Maybe String
    }


type alias SetItem =
    { title : String
    , codes : List String
    , codesText : String
    , kind : ItemKind
    , services : List Service
    , description : String
    , url : String
    , catalog : Maybe SetCatalog
    , photos : List String
    }


emptySetItem : SetItem
emptySetItem =
    { title = ""
    , codes = []
    , codesText = ""
    , kind = Set
    , services = [ Brickset, Rebrickable ]
    , description = ""
    , url = ""
    , catalog = Nothing
    , photos = []
    }


{-| The list's cover photo slot, stored in the PocketBase `photo` file field.
-}
coverPhotoSlot : String
coverPhotoSlot =
    "photo"


{-| Gallery photo slots, in display order. Items refer to these names rather than to filenames.
-}
galleryPhotoSlots : List String
galleryPhotoSlots =
    [ "photo_01", "photo_02", "photo_03", "photo_04", "photo_05", "photo_06", "photo_07", "photo_08", "photo_09", "photo_10" ]


photoSlots : List String
photoSlots =
    coverPhotoSlot :: galleryPhotoSlots


{-| Keeps only known gallery slots, without duplicates, in gallery order.
-}
normalizePhotoSlots : List String -> List String
normalizePhotoSlots slots =
    List.filter (\slot -> List.member slot slots) galleryPhotoSlots


{-| Unselects a gallery slot from every item, so a later upload to that slot is not selected again.
-}
clearPhotoSlotFromItems : String -> List SetItem -> List SetItem
clearPhotoSlotFromItems slot items =
    List.map (\item -> { item | photos = List.filter ((/=) slot) item.photos }) items


type ListStatus
    = Draft
    | Published


statusToString : ListStatus -> String
statusToString status =
    case status of
        Draft ->
            "draft"

        Published ->
            "published"


statusFromString : String -> ListStatus
statusFromString raw =
    case raw of
        "published" ->
            Published

        _ ->
            Draft


type alias ListRecord =
    { id : String
    , title : String
    , description : String
    , markdown : String
    , items : List SetItem
    , status : ListStatus
    , owner : String
    , updated : String
    , savedPhotos : Dict String String
    }


savedPhotoFilename : String -> ListRecord -> Maybe String
savedPhotoFilename slot record =
    Dict.get slot record.savedPhotos


setSavedPhoto : String -> Maybe String -> ListRecord -> ListRecord
setSavedPhoto slot maybeFilename record =
    case maybeFilename of
        Just filename ->
            { record | savedPhotos = Dict.insert slot filename record.savedPhotos }

        Nothing ->
            { record | savedPhotos = Dict.remove slot record.savedPhotos }


type alias ListForm =
    { title : String
    , description : String
    , markdown : String
    , items : List SetItem
    , status : ListStatus
    }


emptyForm : ListForm
emptyForm =
    { title = ""
    , description = ""
    , markdown = ""
    , items = []
    , status = Draft
    }


normalizeCodes : String -> List String
normalizeCodes codesText =
    codesText
        |> String.lines
        |> List.map String.trim
        |> List.filter ((/=) "")


setItemCodesText : String -> SetItem -> SetItem
setItemCodesText codesText item =
    let
        updated =
            { item | codesText = codesText, codes = normalizeCodes codesText }
    in
    if firstLookupCode item == firstLookupCode updated then
        updated

    else
        { updated | catalog = Nothing }


validSetCode : String -> Bool
validSetCode code =
    case String.split "-" (String.trim code) of
        [ number, variant ] ->
            String.length number
                >= 1
                && String.length number
                <= 6
                && String.length variant
                >= 1
                && String.length variant
                <= 3
                && String.all Char.isDigit number
                && String.all Char.isDigit variant

        _ ->
            False


firstLookupCode : SetItem -> Maybe String
firstLookupCode item =
    item.codes
        |> List.map String.trim
        |> List.filter validSetCode
        |> List.head


lookupCodeMatches : String -> SetItem -> Bool
lookupCodeMatches code item =
    firstLookupCode item == Just code


fillTitleFromLookup : String -> String -> String
fillTitleFromLookup currentTitle suggestedTitle =
    if String.trim currentTitle == "" then
        suggestedTitle

    else
        currentTitle


acceptCatalog : SetCatalog -> SetItem -> SetItem
acceptCatalog catalog item =
    if firstLookupCode item == Just catalog.code then
        { item
            | title = fillTitleFromLookup item.title catalog.name
            , catalog = Just catalog
        }

    else
        item


itemHasTitle : SetItem -> Bool
itemHasTitle item =
    String.trim item.title /= ""


itemHasValidCodes : SetItem -> Bool
itemHasValidCodes item =
    case item.kind of
        Moc ->
            True

        Set ->
            List.any (String.trim >> (/=) "") item.codes

        AltBuild ->
            List.any (String.trim >> (/=) "") item.codes


serviceFromString : String -> Maybe Service
serviceFromString service =
    case service of
        "lego" ->
            Just Lego

        "brickset" ->
            Just Brickset

        "bricklink" ->
            Just Bricklink

        "rebrickable" ->
            Just Rebrickable

        _ ->
            Nothing


itemKindFromString : String -> ItemKind
itemKindFromString kind =
    case kind of
        "altbuild" ->
            AltBuild

        "moc" ->
            Moc

        _ ->
            Set


itemKindToString : ItemKind -> String
itemKindToString kind =
    case kind of
        Set ->
            "set"

        AltBuild ->
            "altbuild"

        Moc ->
            "moc"


serviceToString : Service -> String
serviceToString service =
    case service of
        Lego ->
            "lego"

        Brickset ->
            "brickset"

        Bricklink ->
            "bricklink"

        Rebrickable ->
            "rebrickable"


serviceName : Service -> String
serviceName service =
    case service of
        Lego ->
            "LEGO.com"

        Brickset ->
            "Brickset"

        Bricklink ->
            "BrickLink"

        Rebrickable ->
            "Rebrickable"
