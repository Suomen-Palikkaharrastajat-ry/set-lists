module Types exposing (CatalogProvider(..), ItemKind(..), ListForm, ListRecord, ListStatus(..), Service(..), SetCatalog, SetItem, acceptCatalog, emptyForm, emptySetItem, fillTitleFromLookup, firstLookupCode, itemHasTitle, itemHasValidCodes, itemKindFromString, itemKindToString, lookupCodeMatches, normalizeCodes, serviceFromString, serviceName, serviceToString, setItemCodesText, validSetCode)

{-| Domain types for persisted table catalogs and their ordered rows.
-}

import Char


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
    }


type ListStatus
    = Draft
    | Published


type alias ListRecord =
    { id : String
    , title : String
    , description : String
    , markdown : String
    , items : List SetItem
    , status : ListStatus
    , owner : String
    , updated : String
    , photo : Maybe String
    }


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
                && String.all isAsciiDigit number
                && String.all isAsciiDigit variant

        _ ->
            False


isAsciiDigit : Char -> Bool
isAsciiDigit char =
    let
        value =
            Char.toCode char
    in
    value >= 48 && value <= 57


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
