module SetListsTest exposing (suite)

{-| BDD coverage for the persisted ordered rows, service selections, and URLs.
-}

import Api
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import MarkdownSafety
import Route
import Test exposing (Test, describe, test)
import Types exposing (CatalogProvider(..), ItemKind(..), ListStatus(..), Service(..))
import Url


suite : Test
suite =
    describe "table catalogs"
        [ test "Given a hash link to a list, when parsed, then it opens the public list route" <|
            \_ ->
                "https://esite.palikkaharrastajat.fi/#/abc123"
                    |> Url.fromString
                    |> Maybe.map Route.parseUrl
                    |> Expect.equal (Just (Route.PublicList "abc123"))
        , test "Given an async list response, when its id differs from the active public or edit route, then it is stale" <|
            \_ ->
                Expect.all
                    [ \_ -> Route.matchesListId "requested" (Route.PublicList "current") |> Expect.equal False
                    , \_ -> Route.matchesListId "requested" (Route.EditList (Just "current")) |> Expect.equal False
                    , \_ -> Route.matchesListId "current" (Route.PublicList "current") |> Expect.equal True
                    , \_ -> Route.matchesListId "current" (Route.EditList (Just "current")) |> Expect.equal True
                    ]
                    ()
        , test "Given ordered items with multiple codes, when encoded, then the new item schema is retained" <|
            \_ ->
                let
                    value =
                        Api.listBody "owner-id"
                            { title = "Collection"
                            , description = ""
                            , markdown = ""
                            , items =
                                [ { title = "Millennium Falcon", codes = [ "75192-1", "75192-2" ], codesText = "75192-1\n75192-2", kind = Set, services = [ Lego, Bricklink ], description = "**Great set**", url = "https://example.com/info", catalog = Nothing }
                                , { title = "TIE Fighter alternate build", codes = [ "10305-1" ], codesText = "10305-1", kind = AltBuild, services = [], description = "", url = "", catalog = Nothing }
                                , { title = "My MOC", codes = [ "MOC-123" ], codesText = "MOC-123", kind = Moc, services = [ Brickset ], description = "", url = "", catalog = Nothing }
                                ]
                            , status = Published
                            }
                in
                Expect.all
                    [ \_ ->
                        Encode.encode 0 value
                            |> Decode.decodeString
                                (Decode.field "items" (Decode.list Api.decodeSetItem))
                            |> Expect.equal
                                (Ok
                                    [ { title = "Millennium Falcon", codes = [ "75192-1", "75192-2" ], codesText = "75192-1\n75192-2", kind = Set, services = [ Lego, Bricklink ], description = "**Great set**", url = "https://example.com/info", catalog = Nothing }
                                    , { title = "TIE Fighter alternate build", codes = [ "10305-1" ], codesText = "10305-1", kind = AltBuild, services = [], description = "", url = "", catalog = Nothing }
                                    , { title = "My MOC", codes = [ "MOC-123" ], codesText = "MOC-123", kind = Moc, services = [ Brickset ], description = "", url = "", catalog = Nothing }
                                    ]
                                )
                    , \_ ->
                        Decode.decodeValue (Decode.field "items" (Decode.index 0 (Decode.field "codesText" Decode.string))) value
                            |> Expect.err
                    ]
                    ()
        , test "Given an old item object, when decoded, then the old collection data is not migrated" <|
            \_ ->
                Decode.decodeString Api.decodeSetItem "{\"code\":\"75192-1\",\"services\":[\"lego\"]}"
                    |> Expect.err
        , test "Given an unsafe item URL, when encoded, then the URL field is omitted" <|
            \_ ->
                Api.listBody "owner-id"
                    { title = "List"
                    , description = ""
                    , markdown = ""
                    , status = Draft
                    , items = [ { title = "Unsafe URL", codes = [], codesText = "", kind = Set, services = [], description = "", url = "javascript:alert(1)", catalog = Nothing } ]
                    }
                    |> Decode.decodeValue (Decode.field "items" (Decode.index 0 (Decode.field "url" Decode.string)))
                    |> Expect.err
        , test "Given a service selection, when a set link is rendered, then the provider URL uses that set code" <|
            \_ ->
                Expect.all
                    [ \_ -> Api.serviceHref Lego "75192-1" |> Expect.equal "https://www.lego.com/en-us/search?q=75192-1"
                    , \_ -> Api.serviceHref Brickset "75192-1" |> Expect.equal "https://brickset.com/sets/75192-1"
                    , \_ -> Api.serviceHref Bricklink "75192-1" |> Expect.equal "https://www.bricklink.com/v2/catalog/catalogitem.page?S=75192-1"
                    , \_ -> Api.serviceHref Rebrickable "75192-1" |> Expect.equal "https://rebrickable.com/sets/75192-1/"
                    ]
                    ()
        , test "Given a set code with reserved characters, when a Rebrickable link is rendered, then the code is percent-encoded" <|
            \_ ->
                Api.serviceHref Rebrickable "a/b?c#d"
                    |> Expect.equal "https://rebrickable.com/sets/a%2Fb%3Fc%23d/"
        , test "Given the Rebrickable service, when encoded and decoded, then its selection is retained" <|
            \_ ->
                let
                    item =
                        { title = "Falcon", codes = [ "75192-1" ], codesText = "75192-1", kind = Set, services = [ Rebrickable, Lego ], description = "", url = "", catalog = Nothing }
                in
                Api.listBody "owner-id"
                    { title = "Rebrickable list", description = "", markdown = "", items = [ item ], status = Draft }
                    |> Decode.decodeValue (Decode.field "items" (Decode.index 0 (Decode.field "services" (Decode.list Decode.string))))
                    |> Expect.equal (Ok [ "rebrickable", "lego" ])
        , test "Given the Rebrickable service string, when decoded, then it maps to the Rebrickable service" <|
            \_ ->
                Decode.decodeString Api.decodeSetItem "{\"codes\":[\"75192-1\"],\"type\":\"set\",\"services\":[\"rebrickable\",\"unknown\"]}"
                    |> Result.map .services
                    |> Expect.equal (Ok [ Rebrickable ])
        , test "Given a new item, when created, then Brickset and Rebrickable are selected by default" <|
            \_ ->
                Types.emptySetItem.services
                    |> Expect.equal [ Brickset, Rebrickable ]
        , test "Given each service, when its label is shown, then it has a human-readable name" <|
            \_ ->
                List.map Types.serviceName [ Lego, Brickset, Bricklink, Rebrickable ]
                    |> Expect.equal [ "LEGO.com", "Brickset", "BrickLink", "Rebrickable" ]
        , test "Given draft data, when encoded, then PocketBase receives the private draft status" <|
            \_ ->
                Api.listBody "owner-id" { title = "Draft", description = "", markdown = "", items = [], status = Draft }
                    |> Decode.decodeValue (Decode.field "status" Decode.string)
                    |> Expect.equal (Ok "draft")
        , test "Given whole-list Markdown, when encoded and decoded, then PocketBase uses the content field" <|
            \_ ->
                let
                    body =
                        Api.listBody "owner-id" { title = "Catalog", description = "", markdown = "## Notes", items = [], status = Draft }
                in
                Expect.all
                    [ \_ -> Decode.decodeValue (Decode.field "content" Decode.string) body |> Expect.equal (Ok "## Notes")
                    , \_ -> Decode.decodeValue (Decode.field "markdown" Decode.string) body |> Expect.err
                    , \_ -> Decode.decodeString Api.decodeList "{\"id\":\"list-id\",\"title\":\"Catalog\",\"content\":\"## Notes\",\"status\":\"draft\",\"owner\":\"owner-id\"}" |> Result.map .markdown |> Expect.equal (Ok "## Notes")
                    ]
                    ()
        , test "Given an optional list photo, when a record is decoded, then its filename is retained" <|
            \_ ->
                Decode.decodeString Api.decodeList "{\"id\":\"list-id\",\"title\":\"Catalog\",\"status\":\"published\",\"photo\":\"cover.webp\"}"
                    |> Result.map .photo
                    |> Expect.equal (Ok (Just "cover.webp"))
        , test "Given no list photo, when a record is decoded, then photo is empty" <|
            \_ ->
                Expect.equal
                    [ Ok Nothing, Ok Nothing ]
                    [ Decode.decodeString Api.decodeList "{\"id\":\"list-id\",\"title\":\"Catalog\",\"status\":\"published\"}" |> Result.map .photo
                    , Decode.decodeString Api.decodeList "{\"id\":\"list-id\",\"title\":\"Catalog\",\"status\":\"published\",\"photo\":\"\"}" |> Result.map .photo
                    ]
        , test "Given a list photo, when its URL is built, then the record and file names are path-encoded" <|
            \_ ->
                Decode.decodeString Api.decodeList "{\"id\":\"list/id\",\"title\":\"Catalog\",\"status\":\"published\",\"photo\":\"cover photo.webp\"}"
                    |> Result.map (Api.photoUrl "https://pb.example" Nothing >> Maybe.withDefault "Missing photo URL")
                    |> Expect.equal (Ok "https://pb.example/api/files/table_catalogs/list%2Fid/cover%20photo.webp")
        , test "Given an authenticated photo URL, when built, then the short-lived file token is encoded" <|
            \_ ->
                Decode.decodeString Api.decodeList "{\"id\":\"list-id\",\"title\":\"Catalog\",\"status\":\"draft\",\"photo\":\"cover.webp\"}"
                    |> Result.map (Api.photoUrl "https://pb.example" (Just "file.token/with+symbols") >> Maybe.withDefault "Missing photo URL")
                    |> Expect.equal (Ok "https://pb.example/api/files/table_catalogs/list-id/cover.webp?token=file.token%2Fwith%2Bsymbols")
        , test "Given a list form, when it is encoded, then the separately uploaded photo is not overwritten" <|
            \_ ->
                Api.listBody "owner-id" { title = "Catalog", description = "", markdown = "", items = [], status = Draft }
                    |> Decode.decodeValue (Decode.field "photo" Decode.string)
                    |> Expect.err
        , test "Given safe web and relative Markdown URLs, when checked, then they are retained" <|
            \_ ->
                Expect.equal
                    [ Just "https://example.com/image.png"
                    , Just "mailto:builder@example.com"
                    , Just "/images/set.png"
                    , Just "../images/set.png"
                    , Just "#notes"
                    ]
                    (List.map MarkdownSafety.safeUrl
                        [ "https://example.com/image.png"
                        , "mailto:builder@example.com"
                        , "/images/set.png"
                        , "../images/set.png"
                        , "#notes"
                        ]
                    )
        , test "Given executable or control-obfuscated Markdown URLs, when checked, then they are rejected" <|
            \_ ->
                Expect.equal
                    [ Nothing, Nothing, Nothing, Nothing, Nothing, Nothing, Nothing ]
                    (List.map MarkdownSafety.safeUrl
                        [ "javascript:alert(1)"
                        , "data:text/html,<script>alert(1)</script>"
                        , "vbscript:msgbox(1)"
                        , "java\nscript:alert(1)"
                        , "java\tscript:alert(1)"
                        , "\u{0001}javascript:alert(1)"
                        , "\u{007F}javascript:alert(1)"
                        ]
                    )
        , test "Given an optional item URL, when checked, then only absolute HTTP and HTTPS URLs are allowed" <|
            \_ ->
                Expect.equal
                    [ Just "https://example.com/item", Just "http://example.com/item", Nothing, Nothing, Nothing ]
                    (List.map MarkdownSafety.safeWebUrl
                        [ "https://example.com/item", "http://example.com/item", "/item", "mailto:builder@example.com", "javascript:alert(1)" ]
                    )
        , test "Given a codes textarea ending in a newline, when normalized, then raw text remains and code values are derived" <|
            \_ ->
                let
                    item =
                        Types.setItemCodesText "75192-1\n" { title = "Falcon", codes = [], codesText = "", kind = Set, services = [], description = "", url = "", catalog = Nothing }
                in
                Expect.all
                    [ \_ -> item.codesText |> Expect.equal "75192-1\n"
                    , \_ -> item.codes |> Expect.equal [ "75192-1" ]
                    ]
                    ()
        , test "Given item kinds and code text, when checked for save validity, then MOCs may omit codes or include them" <|
            \_ ->
                Expect.equal
                    [ True, False, False, True, False, True, True ]
                    (List.map Types.itemHasValidCodes
                        [ { title = "Set", codes = [ " 75192-1 " ], codesText = " 75192-1 ", kind = Set, services = [], description = "", url = "", catalog = Nothing }
                        , { title = "Set", codes = [], codesText = " \n ", kind = Set, services = [], description = "", url = "", catalog = Nothing }
                        , { title = "Set", codes = [ "   " ], codesText = "   ", kind = Set, services = [], description = "", url = "", catalog = Nothing }
                        , { title = "Altbuild", codes = [ "10305-1" ], codesText = "10305-1", kind = AltBuild, services = [], description = "", url = "", catalog = Nothing }
                        , { title = "Altbuild", codes = [], codesText = "", kind = AltBuild, services = [], description = "", url = "", catalog = Nothing }
                        , { title = "MOC", codes = [], codesText = "", kind = Moc, services = [], description = "", url = "", catalog = Nothing }
                        , { title = "MOC", codes = [ "MOC-123" ], codesText = "MOC-123", kind = Moc, services = [ Brickset ], description = "", url = "", catalog = Nothing }
                        ]
                    )
        , test "Given a MOC with codes, when encoded and decoded, then its codes and selected services are retained" <|
            \_ ->
                let
                    moc =
                        { title = "My MOC"
                        , codes = [ "MOC-123", "MOC-456" ]
                        , codesText = "MOC-123\nMOC-456"
                        , kind = Moc
                        , services = [ Brickset, Bricklink ]
                        , description = ""
                        , url = ""
                        , catalog = Nothing
                        }
                in
                Api.listBody "owner-id"
                    { title = "MOC list", description = "", markdown = "", items = [ moc ], status = Draft }
                    |> Decode.decodeValue (Decode.field "items" (Decode.index 0 Api.decodeSetItem))
                    |> Expect.equal (Ok moc)
        , test "Given an item without a title, when decoded, then it can still be opened and edited" <|
            \_ ->
                Decode.decodeString Api.decodeSetItem "{\"codes\":[\"75192-1\"],\"type\":\"set\",\"services\":[\"lego\"]}"
                    |> Result.map .title
                    |> Expect.equal (Ok "")
        , test "Given an item title, when checked before saving, then whitespace-only titles are invalid" <|
            \_ ->
                let
                    blankItem =
                        Types.emptySetItem

                    titledItem =
                        { blankItem | title = "  Millennium Falcon " }

                    whitespaceItem =
                        { blankItem | title = " \n " }
                in
                Expect.equal [ True, False ] (List.map Types.itemHasTitle [ titledItem, whitespaceItem ])
        , test "Given lookup metadata, when decoded, then bounded result fields and safe HTTPS images are retained" <|
            \_ ->
                Decode.decodeString Api.decodeSetLookupResult
                    "{\"name\":\"Millennium Falcon\",\"year\":2017,\"pieces\":7541,\"imageUrl\":\"https://cdn.rebrickable.com/media/sets/75192-1.jpg\",\"sourceUrl\":\"https://rebrickable.com/sets/75192-1/\"}"
                    |> Expect.equal
                        (Ok
                            { name = "Millennium Falcon"
                            , year = Just 2017
                            , pieces = Just 7541
                            , imageUrl = Just "https://cdn.rebrickable.com/media/sets/75192-1.jpg"
                            , sourceUrl = "https://rebrickable.com/sets/75192-1/"
                            }
                        )
        , test "Given an unsafe lookup thumbnail, when decoded, then the image is omitted" <|
            \_ ->
                Decode.decodeString Api.decodeSetLookupResult
                    "{\"name\":\"Example\",\"year\":null,\"pieces\":null,\"imageUrl\":\"javascript:alert(1)\",\"sourceUrl\":\"https://brickset.com/sets/75192-1\"}"
                    |> Result.map .imageUrl
                    |> Expect.equal (Ok Nothing)
        , test "Given a PocketBase-hosted thumbnail, when decoded, then its HTTPS 256px variant is retained" <|
            \_ ->
                Decode.decodeString Api.decodeSetLookupResult
                    "{\"name\":\"Millennium Falcon\",\"year\":2017,\"pieces\":7541,\"imageUrl\":\"https://data.palikkaharrastajat.fi/api/files/table_thumbnails/abc123/set-75192-1.webp\",\"sourceUrl\":\"https://brickset.com/sets/75192-1\"}"
                    |> Result.map .imageUrl
                    |> Expect.equal (Ok (Just "https://data.palikkaharrastajat.fi/api/files/table_thumbnails/abc123/set-75192-1.webp"))
        , test "Given a Rebrickable suggestion, when decoded, then canonical identity and metadata are retained" <|
            \_ ->
                Decode.decodeString Api.decodeSetSuggestion
                    "{\"code\":\"75192-1\",\"name\":\"Millennium Falcon\",\"year\":2017,\"pieces\":7541,\"imageUrl\":null,\"sourceUrl\":\"https://rebrickable.com/sets/75192-1/\"}"
                    |> Expect.equal
                        (Ok
                            { code = "75192-1"
                            , name = "Millennium Falcon"
                            , year = Just 2017
                            , pieces = Just 7541
                            , imageUrl = Nothing
                            , sourceUrl = "https://rebrickable.com/sets/75192-1/"
                            }
                        )
        , test "Given an accepted catalog snapshot, when encoded and decoded, then only its persisted fields are retained" <|
            \_ ->
                let
                    item =
                        { title = "Falcon"
                        , codes = [ "75192-1" ]
                        , codesText = "75192-1"
                        , kind = Set
                        , services = [ Rebrickable, Brickset ]
                        , description = ""
                        , url = ""
                        , catalog =
                            Just
                                { provider = RebrickableCatalog
                                , code = "75192-1"
                                , name = "Millennium Falcon"
                                , year = Just 2017
                                , pieces = Just 7541
                                , imageUrl = Just "https://cdn.rebrickable.com/media/sets/75192-1.jpg"
                                }
                        }

                    value =
                        Api.listBody "owner-id" { title = "Catalog", description = "", markdown = "", items = [ item ], status = Draft }
                in
                Expect.all
                    [ \_ ->
                        Decode.decodeValue (Decode.field "items" (Decode.index 0 Api.decodeSetItem)) value
                            |> Expect.equal (Ok item)
                    , \_ ->
                        Decode.decodeValue (Decode.field "items" (Decode.index 0 (Decode.field "catalog" Decode.value))) value
                            |> Expect.equal
                                (Decode.decodeString Decode.value
                                    "{\"provider\":\"rebrickable\",\"code\":\"75192-1\",\"name\":\"Millennium Falcon\",\"year\":2017,\"pieces\":7541,\"imageUrl\":\"https://cdn.rebrickable.com/media/sets/75192-1.jpg\"}"
                                )
                    ]
                    ()
        , test "Given a snapshot for a different code, when encoded, then the catalog field is omitted" <|
            \_ ->
                let
                    emptyItem =
                        Types.emptySetItem

                    item =
                        { emptyItem
                            | title = "Falcon"
                            , codes = [ "10305-1" ]
                            , codesText = "10305-1"
                            , catalog =
                                Just
                                    { provider = RebrickableCatalog
                                    , code = "75192-1"
                                    , name = "Millennium Falcon"
                                    , year = Just 2017
                                    , pieces = Just 7541
                                    , imageUrl = Just "https://cdn.rebrickable.com/media/sets/75192-1.jpg"
                                    }
                        }
                in
                Api.listBody "owner-id" { title = "Catalog", description = "", markdown = "", items = [ item ], status = Draft }
                    |> Decode.decodeValue (Decode.field "items" (Decode.index 0 (Decode.field "catalog" Decode.value)))
                    |> Expect.err
        , test "Given a malformed or mismatched catalog snapshot, when decoded, then the item is retained without the snapshot" <|
            \_ ->
                Expect.equal
                    [ Ok Nothing, Ok Nothing ]
                    (List.map
                        (\json -> Decode.decodeString Api.decodeSetItem json |> Result.map .catalog)
                        [ "{\"codes\":[\"75192-1\"],\"type\":\"set\",\"services\":[],\"catalog\":{\"provider\":true}}"
                        , "{\"codes\":[\"10305-1\"],\"type\":\"set\",\"services\":[],\"catalog\":{\"provider\":\"brickset\",\"code\":\"75192-1\",\"name\":\"Falcon\",\"year\":null,\"pieces\":null,\"imageUrl\":null}}"
                        ]
                    )
        , test "Given a catalog image URL, when decoded, then only approved HTTPS image hosts are retained" <|
            \_ ->
                let
                    decodeImage url =
                        Decode.decodeString Api.decodeSetItem
                            ("{\"codes\":[\"75192-1\"],\"type\":\"set\",\"services\":[],\"catalog\":{\"provider\":\"rebrickable\",\"code\":\"75192-1\",\"name\":\"Falcon\",\"year\":null,\"pieces\":null,\"imageUrl\":\"" ++ url ++ "\"}}")
                            |> Result.map (.catalog >> Maybe.andThen .imageUrl)
                in
                Expect.equal
                    [ Ok (Just "https://images.brickset.com/sets/large/75192-1.jpg")
                    , Ok Nothing
                    , Ok Nothing
                    ]
                    [ decodeImage "https://images.brickset.com/sets/large/75192-1.jpg"
                    , decodeImage "https://images.brickset.com.attacker.example/sets/75192.jpg"
                    , decodeImage "http://cdn.rebrickable.com/media/sets/75192.jpg"
                    ]
        , test "Given a provider and set code, when constructing a lookup request, then it uses the authenticated PocketBase endpoint" <|
            \_ ->
                Expect.equal
                    [ "https://pb.example/api/set-lists/lookup?provider=rebrickable&code=75192-1"
                    , "https://pb.example/api/set-lists/lookup?provider=brickset&code=75192-1"
                    , "https://pb.example/api/set-lists/search?q=Millennium%20Falcon"
                    ]
                    [ Api.lookupUrl "https://pb.example" Api.RebrickableProvider "75192-1"
                    , Api.lookupUrl "https://pb.example" Api.BricksetProvider "75192-1"
                    , Api.searchUrl "https://pb.example" "Millennium Falcon"
                    ]
        , test "Given malformed and canonical set codes, when checking lookup eligibility, then only canonical codes pass" <|
            \_ ->
                Expect.equal
                    [ True, True, False, False, False, False ]
                    (List.map Types.validSetCode [ "75192-1", " 10305-12 ", "MOC-123", "75192", "75192-", "75192-1-extra" ])
        , test "Given an item with invalid codes before a valid code, when selecting a lookup code, then the first valid one is used" <|
            \_ ->
                Types.firstLookupCode
                    { title = "Falcon", codes = [ "MOC-123", " 75192-1 ", "10305-1" ], codesText = "", kind = Set, services = [], description = "", url = "", catalog = Nothing }
                    |> Expect.equal (Just "75192-1")
        , test "Given a saved lookup snapshot, when the first valid code changes, then the snapshot is cleared" <|
            \_ ->
                let
                    item =
                        { title = "Falcon"
                        , codes = [ "75192-1", "10305-1" ]
                        , codesText = "75192-1\n10305-1"
                        , kind = Set
                        , services = []
                        , description = ""
                        , url = ""
                        , catalog =
                            Just
                                { provider = RebrickableCatalog
                                , code = "75192-1"
                                , name = "Millennium Falcon"
                                , year = Just 2017
                                , pieces = Just 7541
                                , imageUrl = Nothing
                                }
                        }

                    unchanged =
                        Types.setItemCodesText " 75192-1 \n10305-1" item

                    changed =
                        Types.setItemCodesText "MOC-1\n10305-1" item
                in
                Expect.equal [ Just "75192-1", Nothing ] [ Maybe.map .code unchanged.catalog, changed.catalog |> Maybe.map .code ]
        , test "Given an outstanding lookup, when an item's first valid code changes, then its response is stale" <|
            \_ ->
                let
                    editedItem =
                        { title = "Falcon", codes = [ "10305-1" ], codesText = "10305-1", kind = Set, services = [], description = "", url = "", catalog = Nothing }
                in
                Expect.equal [ True, False ]
                    [ Types.lookupCodeMatches "75192-1" { editedItem | codes = [ "MOC-123", "75192-1" ] }
                    , Types.lookupCodeMatches "75192-1" editedItem
                    ]
        , test "Given a lookup title suggestion, when filling a blank title, then a manually entered title is preserved" <|
            \_ ->
                Expect.equal
                    [ "Millennium Falcon", "My title" ]
                    [ Types.fillTitleFromLookup " \n " "Millennium Falcon"
                    , Types.fillTitleFromLookup "My title" "Millennium Falcon"
                    ]
        , test "Given accepted lookup data, when the title is blank or custom, then it fills only the blank title and stores the snapshot" <|
            \_ ->
                let
                    snapshot =
                        { provider = BricksetCatalog
                        , code = "75192-1"
                        , name = "Millennium Falcon"
                        , year = Just 2017
                        , pieces = Just 7541
                        , imageUrl = Nothing
                        }

                    emptyItem =
                        Types.emptySetItem

                    blank =
                        { emptyItem | codes = [ "75192-1" ], codesText = "75192-1" }

                    custom =
                        { blank | title = "My title" }

                    accepted =
                        [ Types.acceptCatalog snapshot blank
                        , Types.acceptCatalog snapshot custom
                        ]
                in
                Expect.equal
                    [ ( "Millennium Falcon", Just snapshot ), ( "My title", Just snapshot ) ]
                    (List.map (\item -> ( item.title, item.catalog )) accepted)
        ]
