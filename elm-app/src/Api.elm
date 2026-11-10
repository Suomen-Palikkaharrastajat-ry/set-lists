module Api exposing (ListPage, LookupProvider(..), SetLookupResult, decodeList, decodeSetItem, decodeSetLookupResult, deleteList, fetchList, fetchLists, listBody, lookupSet, lookupUrl, saveList, serviceHref)

{-| PocketBase list API, JSON codecs, and service-specific set search links.
-}

import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import MarkdownSafety
import Types exposing (CatalogProvider(..), ListForm, ListRecord, ListStatus(..), Service(..), SetCatalog, SetItem)
import Url


type alias ListPage =
    { page : Int
    , totalPages : Int
    , items : List ListRecord
    }


type LookupProvider
    = RebrickableProvider
    | BricksetProvider


type alias SetLookupResult =
    { name : String
    , year : Maybe Int
    , pieces : Maybe Int
    , imageUrl : Maybe String
    , sourceUrl : String
    }


decodeSetLookupResult : Decoder SetLookupResult
decodeSetLookupResult =
    Decode.map5 SetLookupResult
        (Decode.field "name" Decode.string)
        (Decode.field "year" (Decode.nullable Decode.int))
        (Decode.field "pieces" (Decode.nullable Decode.int))
        (Decode.field "imageUrl" (Decode.map (Maybe.andThen safeThumbnailUrl) (Decode.nullable Decode.string)))
        (Decode.field "sourceUrl" Decode.string)


safeThumbnailUrl : String -> Maybe String
safeThumbnailUrl url =
    MarkdownSafety.safeWebUrl url
        |> Maybe.andThen
            (\safeUrl ->
                Url.fromString safeUrl
                    |> Maybe.andThen
                        (\parsed ->
                            if
                                parsed.protocol
                                    == Url.Https
                                    && List.member (String.toLower parsed.host) [ "cdn.rebrickable.com", "images.brickset.com", "brickset.com", "www.brickset.com" ]
                                    && (parsed.port_ == Nothing || parsed.port_ == Just 443)
                            then
                                Just safeUrl

                            else
                                Nothing
                        )
            )


lookupProviderName : LookupProvider -> String
lookupProviderName provider =
    case provider of
        RebrickableProvider ->
            "rebrickable"

        BricksetProvider ->
            "brickset"


lookupUrl : String -> LookupProvider -> String -> String
lookupUrl baseUrl provider code =
    baseUrl
        ++ "/api/set-lists/lookup?provider="
        ++ lookupProviderName provider
        ++ "&code="
        ++ Url.percentEncode code


decodeList : Decoder ListRecord
decodeList =
    Decode.map8 ListRecord
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.maybe (Decode.field "description" Decode.string) |> Decode.map (Maybe.withDefault ""))
        (Decode.maybe (Decode.field "markdown" Decode.string) |> Decode.map (Maybe.withDefault ""))
        (Decode.maybe (Decode.field "items" (Decode.list decodeSetItem)) |> Decode.map (Maybe.withDefault []))
        (Decode.field "status" Decode.string |> Decode.map statusFromString)
        (Decode.maybe (Decode.field "owner" Decode.string) |> Decode.map (Maybe.withDefault ""))
        (Decode.maybe (Decode.field "updated" Decode.string) |> Decode.map (Maybe.withDefault ""))


decodeSetItem : Decoder SetItem
decodeSetItem =
    Decode.map7
        (\title codes kind services description url catalogValue ->
            let
                normalizedCodes =
                    List.map String.trim codes |> List.filter ((/=) "")

                item =
                    { title = Maybe.withDefault "" title
                    , codes = normalizedCodes
                    , codesText = String.join "\n" normalizedCodes
                    , kind = Types.itemKindFromString kind
                    , services = List.filterMap Types.serviceFromString services
                    , description = Maybe.withDefault "" description
                    , url = url |> Maybe.andThen MarkdownSafety.safeWebUrl |> Maybe.withDefault ""
                    , catalog = Nothing
                    }
            in
            { item | catalog = catalogValue |> Maybe.andThen (decodeCatalog item) }
        )
        (Decode.maybe (Decode.field "title" Decode.string))
        (Decode.field "codes" (Decode.list Decode.string))
        (Decode.field "type" Decode.string)
        (Decode.field "services" (Decode.list Decode.string))
        (Decode.maybe (Decode.field "description" Decode.string))
        (Decode.maybe (Decode.field "url" Decode.string))
        (Decode.maybe (Decode.field "catalog" Decode.value))


decodeCatalog : SetItem -> Decode.Value -> Maybe SetCatalog
decodeCatalog item value =
    case Decode.decodeValue catalogDecoder value of
        Ok catalog ->
            validateCatalog item catalog

        Err _ ->
            Nothing


catalogDecoder : Decoder SetCatalog
catalogDecoder =
    Decode.map6 SetCatalog
        (Decode.field "provider" Decode.string |> Decode.andThen catalogProviderDecoder)
        (Decode.field "code" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "year" (Decode.nullable Decode.int))
        (Decode.field "pieces" (Decode.nullable Decode.int))
        (Decode.field "imageUrl" (Decode.nullable Decode.string))


catalogProviderDecoder : String -> Decoder CatalogProvider
catalogProviderDecoder provider =
    case provider of
        "rebrickable" ->
            Decode.succeed RebrickableCatalog

        "brickset" ->
            Decode.succeed BricksetCatalog

        _ ->
            Decode.fail "Unknown catalog provider"


validateCatalog : SetItem -> SetCatalog -> Maybe SetCatalog
validateCatalog item catalog =
    let
        validNumber maybeNumber minimum maximum =
            maybeNumber
                |> Maybe.map (\number -> number >= minimum && number <= maximum)
                |> Maybe.withDefault True

        name =
            String.trim catalog.name
    in
    if
        Types.firstLookupCode item
            == Just catalog.code
            && Types.validSetCode catalog.code
            && name
            /= ""
            && String.length name
            <= 200
            && validNumber catalog.year 1950 2100
            && validNumber catalog.pieces 0 100000
    then
        Just
            { catalog
                | name = name
                , imageUrl = catalog.imageUrl |> Maybe.andThen safeThumbnailUrl
            }

    else
        Nothing


statusFromString : String -> ListStatus
statusFromString value =
    if value == "published" then
        Published

    else
        Draft


fetchLists : String -> String -> String -> Int -> (Result Http.Error ListPage -> msg) -> Cmd msg
fetchLists baseUrl token ownerId page toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" token ]
        , url =
            baseUrl
                ++ "/api/collections/table_catalogs/records?perPage=200&page="
                ++ String.fromInt page
                ++ "&sort=-updated&filter="
                ++ Url.percentEncode ("owner=\"" ++ ownerId ++ "\"")
        , body = Http.emptyBody
        , expect =
            Http.expectJson toMsg
                (Decode.map3 ListPage
                    (Decode.field "page" Decode.int)
                    (Decode.field "totalPages" Decode.int)
                    (Decode.field "items" (Decode.list decodeList))
                )
        , timeout = Nothing
        , tracker = Nothing
        }


fetchList : String -> Maybe String -> String -> (Result Http.Error ListRecord -> msg) -> Cmd msg
fetchList baseUrl maybeToken id toMsg =
    Http.request
        { method = "GET"
        , headers = maybeToken |> Maybe.map (\token -> [ Http.header "Authorization" token ]) |> Maybe.withDefault []
        , url = baseUrl ++ "/api/collections/table_catalogs/records/" ++ Url.percentEncode id
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg decodeList
        , timeout = Nothing
        , tracker = Nothing
        }


lookupSet : String -> String -> LookupProvider -> String -> (Result Http.Error SetLookupResult -> msg) -> Cmd msg
lookupSet baseUrl token provider code toMsg =
    Http.request
        { method = "GET"
        , headers = [ Http.header "Authorization" token ]
        , url = lookupUrl baseUrl provider code
        , body = Http.emptyBody
        , expect = Http.expectJson toMsg decodeSetLookupResult
        , timeout = Just 8000
        , tracker = Nothing
        }


listBody : String -> ListForm -> Encode.Value
listBody owner form =
    Encode.object
        [ ( "title", Encode.string (String.trim form.title) )
        , ( "description", Encode.string (String.trim form.description) )
        , ( "markdown", Encode.string form.markdown )
        , ( "items"
          , Encode.list encodeSetItem form.items
          )
        , ( "status", Encode.string (statusToString form.status) )
        , ( "owner", Encode.string owner )
        ]


encodeSetItem : SetItem -> Encode.Value
encodeSetItem item =
    Encode.object <|
        [ ( "title", Encode.string (String.trim item.title) )
        , ( "codes", Encode.list (String.trim >> Encode.string) (List.filter (String.trim >> (/=) "") item.codes) )
        , ( "type", Encode.string (Types.itemKindToString item.kind) )
        , ( "services", Encode.list (Types.serviceToString >> Encode.string) item.services )
        ]
            ++ (if String.trim item.description == "" then
                    []

                else
                    [ ( "description", Encode.string item.description ) ]
               )
            ++ (case MarkdownSafety.safeWebUrl item.url of
                    Just safeUrl ->
                        [ ( "url", Encode.string safeUrl ) ]

                    Nothing ->
                        []
               )
            ++ (item.catalog |> Maybe.andThen (validateCatalog item) |> Maybe.map encodeCatalog |> Maybe.map (\catalog -> [ ( "catalog", catalog ) ]) |> Maybe.withDefault [])


encodeCatalog : SetCatalog -> Encode.Value
encodeCatalog catalog =
    Encode.object
        [ ( "provider", Encode.string (catalogProviderName catalog.provider) )
        , ( "code", Encode.string catalog.code )
        , ( "name", Encode.string catalog.name )
        , ( "year", catalog.year |> Maybe.map Encode.int |> Maybe.withDefault Encode.null )
        , ( "pieces", catalog.pieces |> Maybe.map Encode.int |> Maybe.withDefault Encode.null )
        , ( "imageUrl", catalog.imageUrl |> Maybe.andThen safeThumbnailUrl |> Maybe.map Encode.string |> Maybe.withDefault Encode.null )
        ]


catalogProviderName : CatalogProvider -> String
catalogProviderName provider =
    case provider of
        RebrickableCatalog ->
            "rebrickable"

        BricksetCatalog ->
            "brickset"


statusToString : ListStatus -> String
statusToString status =
    case status of
        Draft ->
            "draft"

        Published ->
            "published"


saveList : String -> String -> String -> Maybe String -> ListForm -> (Result Http.Error ListRecord -> msg) -> Cmd msg
saveList baseUrl token owner maybeId form toMsg =
    let
        method =
            case maybeId of
                Just _ ->
                    "PATCH"

                Nothing ->
                    "POST"

        endpoint =
            baseUrl ++ "/api/collections/table_catalogs/records"

        url =
            case maybeId of
                Just id ->
                    endpoint ++ "/" ++ Url.percentEncode id

                Nothing ->
                    endpoint
    in
    Http.request
        { method = method
        , headers = [ Http.header "Authorization" token ]
        , url = url
        , body = Http.jsonBody (listBody owner form)
        , expect = Http.expectJson toMsg decodeList
        , timeout = Nothing
        , tracker = Nothing
        }


deleteList : String -> String -> String -> (Result Http.Error () -> msg) -> Cmd msg
deleteList baseUrl token id toMsg =
    Http.request
        { method = "DELETE"
        , headers = [ Http.header "Authorization" token ]
        , url = baseUrl ++ "/api/collections/table_catalogs/records/" ++ Url.percentEncode id
        , body = Http.emptyBody
        , expect = Http.expectWhatever toMsg
        , timeout = Nothing
        , tracker = Nothing
        }


serviceHref : Service -> String -> String
serviceHref service code =
    let
        query =
            Url.percentEncode code
    in
    case service of
        Lego ->
            "https://www.lego.com/en-us/search?q=" ++ query

        Brickset ->
            "https://brickset.com/sets/" ++ query

        Bricklink ->
            "https://www.bricklink.com/v2/catalog/catalogitem.page?S=" ++ query

        Rebrickable ->
            "https://rebrickable.com/sets/" ++ query ++ "/"
