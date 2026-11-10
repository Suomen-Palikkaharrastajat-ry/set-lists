port module Main exposing (main)

{-| Hash-routed app for creating, owning, publishing, and sharing LEGO set lists.

i18n-exempt: Initial release exposes Finnish UI only; English is hidden in site configuration.

-}

import Api
import Browser
import Browser.Navigation as Nav
import Component.Account as Account
import Component.Button as Button
import Component.Dialog as Dialog
import Component.Form as Form
import Component.Layout as Layout
import Component.Toast as Toast
import Dict exposing (Dict)
import FeatherIcons
import Html exposing (Html, a, div, fieldset, h1, h2, h3, header, img, input, label, main_, p, section, span, text, textarea)
import Html.Attributes exposing (alt, attribute, checked, class, href, placeholder, src, target, type_, value)
import Html.Events exposing (onCheck, onClick, onInput)
import Http
import Json.Decode as Decode
import Lang
import Markdown.Parser
import Markdown.Renderer
import MarkdownSafety
import PocketBaseAuth exposing (AuthState(..), AuthUser, getToken)
import QRCode
import Route
import SiteSettings exposing (SiteSettings)
import Svg.Attributes as SvgA
import Types exposing (ItemKind(..), ListForm, ListRecord, ListStatus(..), Service(..), SetItem)
import UiStrings
import Url exposing (Url)


type alias Flags =
    { pbBaseUrl : String
    , authToken : Maybe String
    , authModel : Maybe String
    , localPasswordAuth : Bool
    , siteConfig : Decode.Value
    , requestedLang : String
    }


type alias Model =
    { key : Nav.Key
    , url : Url
    , pbBaseUrl : String
    , localPasswordAuth : Bool
    , auth : AuthState
    , route : Route.Route
    , ownedLists : LoadState (List ListRecord)
    , accumulatedLists : List ListRecord
    , currentList : LoadState ListRecord
    , form : ListForm
    , setLookups : Dict Int SetLookupState
    , lookupRequestId : Int
    , markdownPreviewIds : List String
    , saving : Bool
    , notice : Maybe String
    , confirmDelete : Bool
    , loginEmail : String
    , loginPassword : String
    , loginInProgress : Bool
    , site : SiteSettings
    , lang : Lang.Lang
    , menuOpen : Bool
    }


type alias RouteLoad =
    { ownedLists : LoadState (List ListRecord)
    , currentList : LoadState ListRecord
    , form : ListForm
    , cmd : Cmd Msg
    }


type LoadState a
    = NotLoaded
    | Loading
    | Loaded a
    | LoadFailed String


type SetLookupState
    = LookupLoading Int Api.LookupProvider String
    | LookupLoaded Int Api.LookupProvider String Api.SetLookupResult
    | LookupFailed Int Api.LookupProvider String String


type alias LocalPasswordLoginResult =
    { token : String
    , model : String
    , error : String
    }


type Msg
    = UrlRequested Browser.UrlRequest
    | UrlChanged Url
    | LoginClicked
    | LoginEmailChanged String
    | LoginPasswordChanged String
    | LocalPasswordLoginClicked
    | LocalPasswordLoginCompleted LocalPasswordLoginResult
    | OAuthPopupResult { token : String, model : String }
    | LogOut
    | HomeListsLoaded String (Result Http.Error Api.ListPage)
    | ListLoaded String (Result Http.Error ListRecord)
    | TitleChanged String
    | MarkdownChanged String
    | ItemTitleChanged Int String
    | ItemCodesChanged Int String
    | SetLookupClicked Int Api.LookupProvider
    | SetLookupCompleted Int Int Api.LookupProvider String (Result Http.Error Api.SetLookupResult)
    | AcceptLookup Int Int String
    | ItemKindChanged Int String
    | ItemDescriptionChanged Int String
    | ItemUrlChanged Int String
    | ApplyMarkdownFormat String String String String
    | ToggleMarkdownPreview String
    | ToggleMenu
    | CloseMenu
    | NoOp
    | StatusChanged String
    | ToggleService Int Service Bool
    | AddSet
    | RemoveSet Int
    | MoveSet Int Int
    | SaveClicked
    | SaveCompleted (Result Http.Error ListRecord)
    | DeleteClicked
    | ConfirmDelete
    | CancelDelete
    | DeleteCompleted (Result Http.Error ())
    | PrintClicked
    | DismissNotice


port initiateOAuth : String -> Cmd msg


port localPasswordLogin : { email : String, password : String } -> Cmd msg


port oauthPopupResult : ({ token : String, model : String } -> msg) -> Sub msg


port localPasswordLoginResult : (LocalPasswordLoginResult -> msg) -> Sub msg


port saveAuthToken : { token : String, model : String } -> Cmd msg


port clearAuthToken : () -> Cmd msg


port setDocumentLang : String -> Cmd msg


port printDocument : () -> Cmd msg


port applyMarkdownFormatting : { id : String, prefix : String, suffix : String, linePrefix : String } -> Cmd msg


main : Program Flags Model Msg
main =
    Browser.application
        { init = init
        , onUrlRequest = UrlRequested
        , onUrlChange = UrlChanged
        , subscriptions = subscriptions
        , update = update
        , view = view
        }


init : Flags -> Url -> Nav.Key -> ( Model, Cmd Msg )
init flags url key =
    let
        settings =
            SiteSettings.fromFlags (Just flags.requestedLang) flags.siteConfig

        auth =
            PocketBaseAuth.restoreAuthFromFlags flags.authToken flags.authModel

        requestedRoute =
            Route.parseUrl url

        route =
            if requiresAuth requestedRoute && getToken auth == Nothing then
                Route.Home

            else
                requestedRoute

        loaded =
            loadRoute flags.pbBaseUrl auth route
    in
    ( { key = key
      , url = url
      , pbBaseUrl = flags.pbBaseUrl
      , localPasswordAuth = flags.localPasswordAuth
      , auth = auth
      , route = route
      , ownedLists = loaded.ownedLists
      , accumulatedLists = []
      , currentList = loaded.currentList
      , form = loaded.form
      , setLookups = Dict.empty
      , lookupRequestId = 0
      , markdownPreviewIds = []
      , saving = False
      , notice = Nothing
      , confirmDelete = False
      , loginEmail = ""
      , loginPassword = ""
      , loginInProgress = False
      , site = settings.site
      , lang = settings.lang
      , menuOpen = False
      }
    , Cmd.batch
        [ setDocumentLang (Lang.toString settings.lang)
        , loaded.cmd
        , if route /= requestedRoute then
            Nav.replaceUrl key (Route.toHref route)

          else
            Cmd.none
        ]
    )


loadRoute : String -> AuthState -> Route.Route -> RouteLoad
loadRoute baseUrl auth route =
    let
        listCmd id =
            Api.fetchList baseUrl (getToken auth) id (ListLoaded id)
    in
    case route of
        Route.Home ->
            case ( getToken auth, auth ) of
                ( Just token, Authenticated user ) ->
                    { ownedLists = Loading, currentList = NotLoaded, form = Types.emptyForm, cmd = Api.fetchLists baseUrl token user.id 1 (HomeListsLoaded user.id) }

                _ ->
                    { ownedLists = NotLoaded, currentList = NotLoaded, form = Types.emptyForm, cmd = Cmd.none }

        Route.PublicList id ->
            { ownedLists = NotLoaded, currentList = Loading, form = Types.emptyForm, cmd = listCmd id }

        Route.EditList Nothing ->
            { ownedLists = NotLoaded, currentList = NotLoaded, form = Types.emptyForm, cmd = Cmd.none }

        Route.EditList (Just id) ->
            { ownedLists = NotLoaded, currentList = Loading, form = Types.emptyForm, cmd = listCmd id }

        Route.NotFound ->
            { ownedLists = NotLoaded, currentList = NotLoaded, form = Types.emptyForm, cmd = Cmd.none }


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ oauthPopupResult OAuthPopupResult
        , localPasswordLoginResult LocalPasswordLoginCompleted
        , Layout.subscriptions { isOpen = model.menuOpen, onClose = CloseMenu }
        ]


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        UrlRequested request ->
            case request of
                Browser.Internal url ->
                    ( model, Nav.pushUrl model.key (Url.toString url) )

                Browser.External url ->
                    ( model, Nav.load url )

        UrlChanged url ->
            let
                route =
                    Route.parseUrl url

                loaded =
                    loadRoute model.pbBaseUrl model.auth route

                isProtected =
                    requiresAuth route && getToken model.auth == Nothing
            in
            if isProtected then
                ( { model | url = url, route = Route.Home, ownedLists = NotLoaded, accumulatedLists = [], currentList = NotLoaded, setLookups = Dict.empty, confirmDelete = False, menuOpen = False }
                , Nav.pushUrl model.key "#/"
                )

            else
                ( { model | url = url, route = route, ownedLists = loaded.ownedLists, accumulatedLists = [], currentList = loaded.currentList, form = loaded.form, setLookups = Dict.empty, confirmDelete = False, menuOpen = False }
                , Cmd.batch
                    [ loaded.cmd
                    , if model.menuOpen then
                        Layout.onMenuClosed NoOp

                      else
                        Cmd.none
                    ]
                )

        LoginClicked ->
            ( model, initiateOAuth model.pbBaseUrl )

        LoginEmailChanged email ->
            ( { model | loginEmail = email }, Cmd.none )

        LoginPasswordChanged password ->
            ( { model | loginPassword = password }, Cmd.none )

        LocalPasswordLoginClicked ->
            if String.trim model.loginEmail == "" || model.loginPassword == "" then
                ( { model | notice = Just "Anna sähköpostiosoite ja salasana." }, Cmd.none )

            else
                ( { model | loginInProgress = True, notice = Nothing }
                , localPasswordLogin { email = String.trim model.loginEmail, password = model.loginPassword }
                )

        LocalPasswordLoginCompleted result ->
            if result.token == "" then
                ( { model
                    | loginInProgress = False
                    , loginPassword = ""
                    , notice = Just ("Paikallinen kirjautuminen epäonnistui: " ++ result.error)
                  }
                , Cmd.none
                )

            else
                finishLogin { token = result.token, model = result.model } { model | loginInProgress = False, loginPassword = "" }

        OAuthPopupResult data ->
            finishLogin data model

        LogOut ->
            ( { model | auth = NotAuthenticated, ownedLists = NotLoaded, setLookups = Dict.empty, notice = Nothing }
            , Cmd.batch [ clearAuthToken (), Nav.pushUrl model.key "#/" ]
            )

        HomeListsLoaded ownerId result ->
            case ( model.route, model.auth ) of
                ( Route.Home, Authenticated user ) ->
                    if user.id /= ownerId then
                        ( model, Cmd.none )

                    else
                        case result of
                            Ok page ->
                                let
                                    allLists =
                                        model.accumulatedLists ++ page.items
                                in
                                if page.page < page.totalPages then
                                    case getToken model.auth of
                                        Just token ->
                                            ( { model | ownedLists = Loading, accumulatedLists = allLists }
                                            , Api.fetchLists model.pbBaseUrl token ownerId (page.page + 1) (HomeListsLoaded ownerId)
                                            )

                                        Nothing ->
                                            ( { model | ownedLists = NotLoaded, accumulatedLists = [] }, Cmd.none )

                                else
                                    ( { model | ownedLists = Loaded allLists, accumulatedLists = [] }, Cmd.none )

                            Err error ->
                                ( { model | ownedLists = LoadFailed (httpError error), accumulatedLists = [] }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ListLoaded requestedId result ->
            if Route.matchesListId requestedId model.route then
                case result of
                    Ok record ->
                        if record.id /= requestedId then
                            ( model, Cmd.none )

                        else
                            let
                                form =
                                    { title = record.title
                                    , description = record.description
                                    , markdown = record.markdown
                                    , items = record.items
                                    , status = record.status
                                    }
                            in
                            ( { model | currentList = Loaded record, form = form }, Cmd.none )

                    Err error ->
                        ( { model | currentList = LoadFailed (httpError error) }, Cmd.none )

            else
                ( model, Cmd.none )

        TitleChanged title ->
            ( mapForm (\form -> { form | title = title }) model, Cmd.none )

        MarkdownChanged markdown ->
            ( mapForm (\form -> { form | markdown = markdown }) model, Cmd.none )

        ItemTitleChanged index title ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | title = title }) form.items }) model, Cmd.none )

        ItemCodesChanged index codes ->
            let
                updated =
                    mapForm (\form -> { form | items = updateAt index (Types.setItemCodesText codes) form.items }) model
            in
            ( { updated | setLookups = Dict.remove index model.setLookups }, Cmd.none )

        SetLookupClicked index provider ->
            case ( getToken model.auth, List.drop index model.form.items |> List.head |> Maybe.andThen Types.firstLookupCode ) of
                ( Just token, Just code ) ->
                    let
                        requestId =
                            model.lookupRequestId + 1
                    in
                    ( { model | lookupRequestId = requestId, setLookups = Dict.insert index (LookupLoading requestId provider code) model.setLookups }
                    , Api.lookupSet model.pbBaseUrl token provider code (SetLookupCompleted index requestId provider code)
                    )

                ( _, Nothing ) ->
                    ( model, Cmd.none )

                ( Nothing, Just _ ) ->
                    ( { model | setLookups = Dict.insert index (LookupFailed model.lookupRequestId provider "" "Kirjaudu sisään käyttääksesi hakua.") model.setLookups }, Cmd.none )

        SetLookupCompleted index requestId provider code result ->
            let
                matchesPending =
                    case Dict.get index model.setLookups of
                        Just (LookupLoading activeId activeProvider activeCode) ->
                            activeId == requestId && activeProvider == provider && activeCode == code

                        _ ->
                            False

                matchesCurrentItem =
                    List.drop index model.form.items
                        |> List.head
                        |> Maybe.map (Types.lookupCodeMatches code)
                        |> Maybe.withDefault False
            in
            if not matchesPending || not matchesCurrentItem then
                ( model, Cmd.none )

            else
                case result of
                    Ok lookupResult ->
                        ( { model | setLookups = Dict.insert index (LookupLoaded requestId provider code lookupResult) model.setLookups }, Cmd.none )

                    Err (Http.BadStatus 404) ->
                        ( { model | setLookups = Dict.insert index (LookupFailed requestId provider code "Settiä ei löytynyt. Voit syöttää otsikon itse.") model.setLookups }, Cmd.none )

                    Err error ->
                        let
                            message =
                                "Haku ei onnistunut (" ++ httpError error ++ "). Voit syöttää otsikon itse."
                        in
                        ( { model | setLookups = Dict.insert index (LookupFailed requestId provider code message) model.setLookups }, Cmd.none )

        AcceptLookup index requestId code ->
            let
                acceptedResult =
                    case Dict.get index model.setLookups of
                        Just (LookupLoaded activeId provider activeCode result) ->
                            if activeId == requestId && activeCode == code then
                                Just ( provider, result )

                            else
                                Nothing

                        _ ->
                            Nothing

                updateItem ( provider, result ) item =
                    Types.acceptCatalog
                        { provider = catalogProvider provider
                        , code = code
                        , name = result.name
                        , year = result.year
                        , pieces = result.pieces
                        , imageUrl = result.imageUrl
                        }
                        item
            in
            case acceptedResult of
                Just snapshot ->
                    if List.drop index model.form.items |> List.head |> Maybe.map (Types.lookupCodeMatches code) |> Maybe.withDefault False then
                        ( mapForm (\form -> { form | items = updateAt index (updateItem snapshot) form.items }) model, Cmd.none )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        ItemKindChanged index kind ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | kind = Types.itemKindFromString kind }) form.items }) model, Cmd.none )

        ItemDescriptionChanged index description ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | description = description }) form.items }) model, Cmd.none )

        ItemUrlChanged index url ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | url = url }) form.items }) model, Cmd.none )

        ApplyMarkdownFormat id prefix suffix linePrefix ->
            ( model, applyMarkdownFormatting { id = id, prefix = prefix, suffix = suffix, linePrefix = linePrefix } )

        ToggleMarkdownPreview id ->
            ( { model
                | markdownPreviewIds =
                    if List.member id model.markdownPreviewIds then
                        List.filter ((/=) id) model.markdownPreviewIds

                    else
                        id :: model.markdownPreviewIds
              }
            , Cmd.none
            )

        ToggleMenu ->
            if model.menuOpen then
                ( { model | menuOpen = False }, Layout.onMenuClosed NoOp )

            else
                ( { model | menuOpen = True }, Layout.onMenuOpened NoOp )

        CloseMenu ->
            ( { model | menuOpen = False }, Layout.onMenuClosed NoOp )

        NoOp ->
            ( model, Cmd.none )

        StatusChanged state ->
            ( mapForm
                (\form ->
                    { form
                        | status =
                            if state == "published" then
                                Published

                            else
                                Draft
                    }
                )
                model
            , Cmd.none
            )

        ToggleService index service enabled ->
            let
                toggle item =
                    let
                        services =
                            if enabled then
                                if List.member service item.services then
                                    item.services

                                else
                                    item.services ++ [ service ]

                            else
                                List.filter ((/=) service) item.services
                    in
                    { item | services = services }
            in
            ( mapForm (\form -> { form | items = updateAt index toggle form.items }) model, Cmd.none )

        AddSet ->
            let
                updated =
                    mapForm (\form -> { form | items = form.items ++ [ Types.emptySetItem ] }) model
            in
            ( { updated | setLookups = Dict.empty }, Cmd.none )

        RemoveSet index ->
            let
                updated =
                    mapForm
                        (\form -> { form | items = List.indexedMap Tuple.pair form.items |> List.filter (Tuple.first >> (/=) index) |> List.map Tuple.second })
                        model
            in
            ( { updated | setLookups = Dict.empty }
            , Cmd.none
            )

        MoveSet from to ->
            let
                updated =
                    mapForm (\form -> { form | items = moveItem from to form.items }) model
            in
            ( { updated | setLookups = Dict.empty }, Cmd.none )

        SaveClicked ->
            case ( getToken model.auth, model.auth, model.route ) of
                ( Just token, Authenticated user, Route.EditList maybeId ) ->
                    if String.trim model.form.title == "" then
                        ( { model | notice = Just "Anna listalle otsikko ennen tallentamista." }, Cmd.none )

                    else if List.any (Types.itemHasTitle >> not) model.form.items then
                        ( { model | notice = Just "Anna jokaiselle kohteelle otsikko ennen tallentamista." }, Cmd.none )

                    else if List.any (Types.itemHasValidCodes >> not) model.form.items then
                        ( { model | notice = Just "Lisää vähintään yksi LEGO-tunnus jokaiselle setille ja vaihtoehtoiselle rakennelmalle ennen tallentamista." }, Cmd.none )

                    else if List.any (\item -> String.trim item.url /= "" && MarkdownSafety.safeWebUrl item.url == Nothing) model.form.items then
                        ( { model | notice = Just "Lisätietojen URL-osoitteen tulee alkaa http:// tai https://." }, Cmd.none )

                    else
                        ( { model | saving = True, notice = Nothing }
                        , Api.saveList model.pbBaseUrl token user.id maybeId model.form SaveCompleted
                        )

                ( _, _, _ ) ->
                    ( { model | notice = Just "Kirjaudu sisään tallentaaksesi listan." }, Cmd.none )

        SaveCompleted result ->
            case result of
                Ok record ->
                    ( { model | saving = False, currentList = Loaded record, notice = Just "Lista tallennettiin." }
                    , Nav.pushUrl model.key (Route.toHref (Route.PublicList record.id))
                    )

                Err error ->
                    ( { model | saving = False, notice = Just ("Tallennus epäonnistui: " ++ httpError error) }, Cmd.none )

        DeleteClicked ->
            case model.route of
                Route.EditList (Just _) ->
                    ( { model | confirmDelete = True }, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ConfirmDelete ->
            case ( getToken model.auth, model.route ) of
                ( Just token, Route.EditList (Just id) ) ->
                    ( { model | saving = True, confirmDelete = False }, Api.deleteList model.pbBaseUrl token id DeleteCompleted )

                _ ->
                    ( model, Cmd.none )

        CancelDelete ->
            ( { model | confirmDelete = False }, Cmd.none )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = False, confirmDelete = False, notice = Just "Lista poistettiin." }, Nav.pushUrl model.key "#/" )

                Err error ->
                    ( { model | saving = False, confirmDelete = False, notice = Just ("Poisto epäonnistui: " ++ httpError error) }, Cmd.none )

        PrintClicked ->
            ( model, printDocument () )

        DismissNotice ->
            ( { model | notice = Nothing }, Cmd.none )


finishLogin : { token : String, model : String } -> Model -> ( Model, Cmd Msg )
finishLogin data model =
    case PocketBaseAuth.userFromPopupResult data of
        Just user ->
            let
                loaded =
                    loadRoute model.pbBaseUrl (Authenticated user) model.route
            in
            ( { model
                | auth = Authenticated user
                , ownedLists = loaded.ownedLists
                , accumulatedLists = []
                , currentList = loaded.currentList
                , form = loaded.form
                , notice = Just "Kirjautuminen onnistui."
                , confirmDelete = False
                , loginPassword = ""
                , loginInProgress = False
              }
            , Cmd.batch [ saveAuthToken { token = data.token, model = data.model }, loaded.cmd ]
            )

        Nothing ->
            ( { model | loginInProgress = False, loginPassword = "", notice = Just "Kirjautuminen ei onnistunut." }, Cmd.none )


httpError : Http.Error -> String
httpError error =
    case error of
        Http.BadUrl _ ->
            "Virheellinen palvelinosoite."

        Http.Timeout ->
            "Palvelin ei vastannut ajoissa."

        Http.NetworkError ->
            "Verkkovirhe. Tarkista yhteys ja yritä uudelleen."

        Http.BadStatus status ->
            "Palvelin palautti virheen " ++ String.fromInt status ++ "."

        Http.BadBody _ ->
            "Palvelimen vastausta ei voitu lukea."


updateAt : Int -> (a -> a) -> List a -> List a
updateAt index transform values =
    List.indexedMap
        (\current value ->
            if current == index then
                transform value

            else
                value
        )
        values


moveItem : Int -> Int -> List a -> List a
moveItem from to values =
    case List.drop from values |> List.head of
        Nothing ->
            values

        Just item ->
            let
                remaining =
                    List.take from values ++ List.drop (from + 1) values

                safePosition =
                    clamp 0 (List.length remaining) to
            in
            List.take safePosition remaining ++ [ item ] ++ List.drop safePosition remaining


clamp : Int -> Int -> Int -> Int
clamp low high value =
    max low (min high value)


mapForm : (ListForm -> ListForm) -> Model -> Model
mapForm transform model =
    { model | form = transform model.form }


requiresAuth : Route.Route -> Bool
requiresAuth route =
    case route of
        Route.EditList _ ->
            True

        _ ->
            False


view : Model -> Browser.Document Msg
view model =
    let
        anonymousPublicList =
            isAnonymousPublicList model
    in
    { title = "Palikkalistat"
    , body =
        Layout.view
            { site = model.site
            , strings = UiStrings.forLang model.lang
            , attributes = [ class "min-h-screen flex flex-col bg-bg-page text-text-primary" ]
            , home =
                { href =
                    if anonymousPublicList then
                        Route.toHref model.route

                    else
                        "#/"
                , onClick = Nothing
                }
            , links =
                if anonymousPublicList then
                    []

                else
                    [ { label = "Omat listat"
                      , href = "#/"
                      , mobileOnly = False
                      , isActive = model.route == Route.Home
                      }
                    ]
            , headerActions =
                if anonymousPublicList then
                    []

                else
                    [ Account.viewHeader (accountConfig model) ]
            , showHeader = not anonymousPublicList
            , menu =
                if anonymousPublicList then
                    Nothing

                else
                    Just
                        { isOpen = model.menuOpen
                        , onToggle = ToggleMenu
                        , onClose = CloseMenu
                        , content =
                            \links ->
                                [ Html.nav [ attribute "aria-label" (UiStrings.forLang model.lang).mainNav, class "p-4" ] [ links ]
                                , div [ class "border-t border-border-default p-4" ] [ Account.viewDrawer (accountConfig model) ]
                                ]
                        }
            , main =
                if anonymousPublicList then
                    main_ [ attribute "id" "main-content", class "w-full flex-1" ]
                        [ viewAnonymousBrandBar model
                        , div [ class "mx-auto w-full max-w-5xl px-3 py-4 sm:px-4 sm:py-8" ] [ viewPage model ]
                        ]

                else
                    main_ [ attribute "id" "main-content", class "mx-auto w-full max-w-5xl flex-1 px-4 py-8" ] [ viewPage model ]
            , aboveFooter = []
            , footer =
                if anonymousPublicList then
                    Nothing

                else
                    Just { topMargin = False, extra = [] }
            , scrollToTop = Nothing
            , toasts = Just (noticeToasts model.notice)
            , overlays = [ viewDeleteConfirmation model.confirmDelete ]
            }
    }


viewAnonymousBrandBar : Model -> Html Msg
viewAnonymousBrandBar model =
    header [ class "no-print w-full bg-brand" ]
        [ div [ class "mx-auto flex max-w-5xl items-center gap-2 px-3 py-2 sm:px-4" ]
            [ img
                [ attribute "src" model.site.branding.logoSquare
                , attribute "alt" ""
                , attribute "aria-hidden" "true"
                , class "h-8 w-8"
                ]
                []
            , span [ class "type-h4 text-text-on-dark" ] [ text model.site.site.title ]
            ]
        ]


isAnonymousPublicList : Model -> Bool
isAnonymousPublicList model =
    case ( model.route, model.auth ) of
        ( Route.PublicList _, NotAuthenticated ) ->
            True

        _ ->
            False


accountConfig : Model -> { strings : UiStrings.UiStrings, user : Maybe AuthUser, onSignIn : Msg, onSignOut : Msg }
accountConfig model =
    { strings = UiStrings.forLang model.lang
    , user =
        case model.auth of
            Authenticated user ->
                Just user

            NotAuthenticated ->
                Nothing
    , onSignIn = LoginClicked
    , onSignOut = LogOut
    }


noticeToasts : Maybe String -> List (Toast.Toast Msg)
noticeToasts maybeNotice =
    case maybeNotice of
        Just message ->
            [ { id = "notice"
              , title = Nothing
              , body = message
              , variant = Toast.Default
              , onClose = Just DismissNotice
              }
            ]

        Nothing ->
            []


viewPage : Model -> Html Msg
viewPage model =
    case model.route of
        Route.Home ->
            viewHome model

        Route.PublicList _ ->
            viewPublicList model

        Route.EditList maybeId ->
            viewEditor model maybeId

        Route.NotFound ->
            section [ class "rounded-lg border border-border-default bg-white p-6" ]
                [ h1 [ class "type-h1" ] [ text "Listaa ei löytynyt" ]
                , p [ class "type-body" ] [ text "Tarkista osoite tai palaa etusivulle." ]
                , a [ href "#/", class "text-brand underline" ] [ text "Etusivulle" ]
                ]


viewHome : Model -> Html Msg
viewHome model =
    case model.auth of
        NotAuthenticated ->
            section [ class "mx-auto max-w-2xl rounded-lg border border-border-default bg-white p-6 sm:p-10" ]
                [ h1 [ class "type-h1" ] [ text "Luo ja jaa LEGO-settilistoja" ]
                , p [ class "type-body mt-4" ] [ text "Kirjaudu sisään luodaksesi omia listoja. Julkaistuja listoja voi tarkastella niiden omalla linkillä." ]
                , if model.localPasswordAuth then
                    div [ class "mt-6 max-w-md space-y-4" ]
                        [ p [ class "type-caption text-text-muted" ] [ text "Paikallinen kehityskirjautuminen" ]
                        , fieldLabel "Sähköposti"
                            "login-email"
                            (input
                                [ type_ "email"
                                , value model.loginEmail
                                , onInput LoginEmailChanged
                                , attribute "autocomplete" "username"
                                , class inputClass
                                ]
                                []
                            )
                        , fieldLabel "Salasana"
                            "login-password"
                            (input
                                [ type_ "password"
                                , value model.loginPassword
                                , onInput LoginPasswordChanged
                                , attribute "autocomplete" "current-password"
                                , class inputClass
                                ]
                                []
                            )
                        , sharedButton
                            (if model.loginInProgress then
                                "Kirjaudutaan…"

                             else
                                "Kirjaudu paikallisesti"
                            )
                            LocalPasswordLoginClicked
                            Button.Primary
                            model.loginInProgress
                            model.loginInProgress
                        ]

                  else
                    div [ class "mt-6" ] [ sharedButton "Kirjaudu sisään" LoginClicked Button.Primary False False ]
                ]

        Authenticated _ ->
            section []
                [ div [ class "mb-6 flex flex-wrap items-center justify-between gap-4" ]
                    [ div []
                        [ h1 [ class "type-h1" ] [ text "Omat listat" ]
                        , p [ class "type-body mt-2 text-text-muted" ] [ text "Hallinnoi luonnoksia ja jaettuja LEGO-settilistoja." ]
                        ]
                    , Button.link { label = "Luo uusi lista", href = "#/lists/new" }
                        |> Button.withVariant Button.Primary
                        |> Button.toHtml
                    ]
                , case model.ownedLists of
                    Loading ->
                        p [ class "type-body" ] [ text "Ladataan listoja…" ]

                    LoadFailed message ->
                        p [ class "type-body text-brand-red" ] [ text message ]

                    Loaded lists ->
                        let
                            ownerId =
                                case model.auth of
                                    Authenticated user ->
                                        user.id

                                    NotAuthenticated ->
                                        ""

                            own =
                                List.filter (\record -> record.owner == ownerId) lists
                        in
                        if List.isEmpty own then
                            p [ class "rounded-lg border border-border-default bg-white p-6 type-body" ] [ text "Sinulla ei ole vielä listoja. Luo ensimmäinen listasi!" ]

                        else
                            div [ class "grid gap-4 md:grid-cols-2" ] (List.map viewListCard own)

                    NotLoaded ->
                        text ""
                ]


viewListCard : ListRecord -> Html Msg
viewListCard record =
    section [ class "rounded-lg border border-border-default bg-white p-5" ]
        [ div [ class "flex items-start justify-between gap-3" ]
            [ h2 [ class "type-h3" ] [ text record.title ]
            , statusBadge record.status
            ]
        , p [ class "mt-2 type-caption text-text-muted" ] [ text (String.fromInt (List.length record.items) ++ " settiä") ]
        , div [ class "mt-4 flex flex-wrap gap-3" ]
            [ a [ href (Route.toHref (Route.PublicList record.id)), class "text-brand underline" ] [ text "Avaa" ]
            , a [ href (Route.toHref (Route.EditList (Just record.id))), class "text-brand underline" ] [ text "Muokkaa" ]
            ]
        ]


statusBadge : ListStatus -> Html Msg
statusBadge status =
    case status of
        Draft ->
            span [ class "rounded bg-bg-subtle px-2 py-1 type-caption text-text-muted" ] [ text "Luonnos" ]

        Published ->
            span [ class "rounded bg-brand-green px-2 py-1 type-caption text-text-on-dark" ] [ text "Julkaistu" ]


viewPublicList : Model -> Html Msg
viewPublicList model =
    case model.currentList of
        Loading ->
            p [ class "type-body" ] [ text "Ladataan listaa…" ]

        LoadFailed message ->
            section [ class "rounded-lg border border-border-default bg-white p-6" ]
                [ h1 [ class "type-h1" ] [ text "Listaa ei löytynyt" ]
                , p [ class "mt-3 type-body text-text-muted" ] [ text message ]
                , a [ href "#/", class "mt-4 inline-block text-brand underline" ] [ text "Etusivulle" ]
                ]

        Loaded record ->
            let
                owned =
                    case model.auth of
                        Authenticated user ->
                            user.id == record.owner

                        NotAuthenticated ->
                            False
            in
            if record.status == Draft && not owned then
                section [ class "rounded-lg bg-white p-6" ] [ h1 [ class "type-h1" ] [ text "Listaa ei löytynyt" ] ]

            else
                viewListDetail (isAuthenticated model.auth) owned record

        NotLoaded ->
            text ""


isAuthenticated : AuthState -> Bool
isAuthenticated auth =
    case auth of
        Authenticated _ ->
            True

        NotAuthenticated ->
            False


viewListDetail : Bool -> Bool -> ListRecord -> Html Msg
viewListDetail authenticated owned record =
    let
        containerClass =
            if authenticated then
                "print-list mx-auto max-w-3xl rounded-lg border border-border-default bg-white p-5 shadow-sm sm:p-8"

            else
                "print-list anonymous-list mx-auto max-w-3xl bg-white p-0 sm:p-2"

        itemsClass =
            if authenticated then
                "mt-7 divide-y divide-border-default"

            else
                "mt-5"
    in
    section [ class containerClass ]
        [ if authenticated then
            div [ class "no-print mb-5 flex flex-wrap items-center justify-between gap-3" ]
                [ a [ href "#/", class "text-brand underline" ] [ text "← Omat listat" ]
                , div [ class "flex gap-2" ]
                    ((if record.status == Published then
                        [ sharedButton "Tulosta" PrintClicked Button.Secondary False False ]

                      else
                        []
                     )
                        ++ (if owned then
                                [ Button.link { label = "Muokkaa", href = Route.toHref (Route.EditList (Just record.id)) }
                                    |> Button.withVariant Button.Secondary
                                    |> Button.withSize Button.Small
                                    |> Button.toHtml
                                ]

                            else
                                []
                           )
                    )
                ]

          else
            text ""
        , div [ class "flex flex-wrap items-start justify-between gap-4" ]
            ([ div []
                [ h1 [ class "type-h1" ] [ text record.title ]
                , viewMarkdown record.markdown
                ]
             ]
                ++ (if authenticated then
                        [ statusBadge record.status ]

                    else
                        []
                   )
            )
        , div [ class itemsClass ] (List.indexedMap viewSet record.items)
        , if record.status == Published then
            viewPrintQr record.id

          else
            text ""
        ]


viewSet : Int -> SetItem -> Html Msg
viewSet index item =
    section [ class "print-break flex flex-wrap items-start gap-4 py-4" ]
        [ span [ class "type-mono text-text-muted" ] [ text (String.fromInt (index + 1) ++ ".") ]
        , div [ class "min-w-0 flex-1" ]
            [ div [ class "flex flex-wrap items-baseline gap-3" ]
                [ h2 [ class "type-h3" ]
                    [ text
                        (if String.trim item.title == "" then
                            itemKindName item.kind

                         else
                            item.title
                        )
                    ]
                , span [ class "rounded bg-bg-subtle px-2 py-1 type-caption text-text-muted" ] [ text (itemKindName item.kind) ]
                , case MarkdownSafety.safeWebUrl item.url of
                    Just safeUrl ->
                        a [ href safeUrl, target "_blank", attribute "rel" "noopener noreferrer", class "text-brand underline" ] [ text "Lisätietoja" ]

                    Nothing ->
                        text ""
                ]
            , viewCatalogSnapshot item.catalog
            , if List.isEmpty item.codes then
                p [ class "mt-2 type-caption text-text-muted" ] [ text "Ei LEGO-tunnuksia" ]

              else
                div [ class "mt-3 space-y-3" ] (List.map (viewCodeLinks item.services) item.codes)
            , viewMarkdown item.description
            ]
        ]


viewCatalogSnapshot : Maybe Types.SetCatalog -> Html Msg
viewCatalogSnapshot maybeCatalog =
    case maybeCatalog of
        Just catalog ->
            div [ class "mt-2 flex flex-wrap items-center gap-3 type-caption text-text-muted" ]
                ((case catalog.imageUrl of
                    Just imageUrl ->
                        [ img [ src imageUrl, alt (catalog.name ++ " - " ++ lookupProviderLabel (lookupProvider catalog.provider)), attribute "loading" "lazy", attribute "referrerpolicy" "no-referrer", class "h-16 w-16 rounded object-contain" ] [] ]

                    Nothing ->
                        []
                 )
                    ++ [ span [] [ text (catalogSummary catalog) ] ]
                )

        Nothing ->
            text ""


catalogSummary : Types.SetCatalog -> String
catalogSummary catalog =
    catalog.name
        ++ (catalog.year |> Maybe.map (\year -> " · " ++ String.fromInt year) |> Maybe.withDefault "")
        ++ (catalog.pieces |> Maybe.map (\pieces -> " · " ++ String.fromInt pieces ++ " osaa") |> Maybe.withDefault "")


lookupProvider : Types.CatalogProvider -> Api.LookupProvider
lookupProvider provider =
    case provider of
        Types.RebrickableCatalog ->
            Api.RebrickableProvider

        Types.BricksetCatalog ->
            Api.BricksetProvider


catalogProvider : Api.LookupProvider -> Types.CatalogProvider
catalogProvider provider =
    case provider of
        Api.RebrickableProvider ->
            Types.RebrickableCatalog

        Api.BricksetProvider ->
            Types.BricksetCatalog


viewCodeLinks : List Service -> String -> Html Msg
viewCodeLinks services code =
    div [ class "flex flex-wrap items-baseline gap-x-4 gap-y-2" ]
        ([ span [ class "type-mono" ] [ text code ] ]
            ++ (if List.isEmpty services then
                    [ span [ class "type-caption text-text-muted" ] [ text "Ei valittuja palveluita" ] ]

                else
                    List.map
                        (\service -> a [ href (Api.serviceHref service code), target "_blank", attribute "rel" "noopener noreferrer", class "type-body-small text-brand underline" ] [ text (Types.serviceName service) ])
                        services
               )
        )


itemKindName : ItemKind -> String
itemKindName kind =
    case kind of
        Set ->
            "Setti"

        AltBuild ->
            "Vaihtoehtoinen rakennelma"

        Moc ->
            "MOC"


statusValue : ListStatus -> String
statusValue status =
    case status of
        Draft ->
            "draft"

        Published ->
            "published"


viewMarkdown : String -> Html Msg
viewMarkdown markdown =
    if String.trim markdown == "" then
        text ""

    else
        section [ class "markdown-content mt-8 max-w-none border-t border-border-default pt-6 type-body" ] (markdownNodes markdown)


viewMarkdownPreview : String -> Html Msg
viewMarkdownPreview markdown =
    if String.trim markdown == "" then
        p [ class "whitespace-pre-wrap type-body text-text-muted" ] [ text "Esikatseltavaa tekstiä ei vielä ole." ]

    else
        div [ class "markdown-content type-body" ] (markdownNodes markdown)


markdownNodes : String -> List (Html Msg)
markdownNodes markdown =
    case Markdown.Parser.parse markdown of
        Ok blocks ->
            case Markdown.Renderer.render safeMarkdownRenderer blocks of
                Ok nodes ->
                    nodes

                Err _ ->
                    [ p [ class "whitespace-pre-wrap type-body" ] [ text markdown ] ]

        Err _ ->
            [ p [ class "whitespace-pre-wrap type-body" ] [ text markdown ] ]


safeMarkdownRenderer : Markdown.Renderer.Renderer (Html Msg)
safeMarkdownRenderer =
    let
        defaultRenderer =
            Markdown.Renderer.defaultHtmlRenderer

        safeLink link children =
            case MarkdownSafety.safeUrl link.destination of
                Just destination ->
                    defaultRenderer.link { link | destination = destination } children

                Nothing ->
                    span [] children

        safeImage imageInfo =
            case MarkdownSafety.safeUrl imageInfo.src of
                Just src ->
                    defaultRenderer.image { imageInfo | src = src }

                Nothing ->
                    span [] [ text imageInfo.alt ]
    in
    { defaultRenderer | link = safeLink, image = safeImage }


viewPrintQr : String -> Html Msg
viewPrintQr id =
    let
        publicUrl =
            "https://listat.palikkaharrastajat.fi/#/" ++ id
    in
    case QRCode.fromString publicUrl of
        Ok qr ->
            div [ class "print-only print-qr" ]
                [ div [ class "print-qr-code" ]
                    [ QRCode.toSvg [ SvgA.width "160", SvgA.height "160" ] qr ]
                ]

        Err _ ->
            text ""


viewEditor : Model -> Maybe String -> Html Msg
viewEditor model maybeId =
    case model.auth of
        NotAuthenticated ->
            section [ class "rounded-lg bg-white p-6" ]
                [ h1 [ class "type-h1" ] [ text "Kirjautuminen vaaditaan" ]
                , p [ class "mt-3 type-body" ] [ text "Kirjaudu sisään hallitaksesi listoja." ]
                , sharedButton "Kirjaudu sisään" LoginClicked Button.Primary False False
                ]

        Authenticated _ ->
            case maybeId of
                Just _ ->
                    case model.currentList of
                        Loading ->
                            p [ class "type-body" ] [ text "Ladataan muokattavaa listaa…" ]

                        LoadFailed error ->
                            p [ class "type-body text-brand-red" ] [ text ("Listaa ei voitu avata: " ++ error) ]

                        Loaded record ->
                            case model.auth of
                                Authenticated user ->
                                    if user.id == record.owner then
                                        viewEditForm model maybeId

                                    else
                                        p [ class "type-body text-brand-red" ] [ text "Tätä listaa ei voi muokata tällä käyttäjällä." ]

                                NotAuthenticated ->
                                    text ""

                        NotLoaded ->
                            text ""

                Nothing ->
                    viewEditForm model maybeId


viewEditForm : Model -> Maybe String -> Html Msg
viewEditForm model maybeId =
    section [ class "mx-auto max-w-3xl" ]
        [ div [ class "mb-6 flex items-center justify-between gap-4" ]
            [ div []
                [ h1 [ class "type-h1" ]
                    [ text
                        (if maybeId == Nothing then
                            "Uusi settilista"

                         else
                            "Muokkaa settilistaa"
                        )
                    ]
                , p [ class "mt-2 type-body text-text-muted" ] [ text "Lisää setit haluamaasi järjestykseen ja valitse kullekin listalle sopivat linkkipalvelut." ]
                ]
            , a [ href "#/", class "text-brand underline" ] [ text "Peruuta" ]
            ]
        , div [ class "space-y-6 rounded-lg border border-border-default bg-white p-5 sm:p-8" ]
            [ if maybeId /= Nothing then
                viewEditSets model

              else
                text ""
            , Form.textInput (Form.defaultField "title" "Listan otsikko")
                { value = model.form.title
                , onInput = TitleChanged
                , inputType = Form.Text
                , placeholder = Just "Esim. Keskiaikaiset linnat"
                }
            , markdownEditor (List.member "list-markdown" model.markdownPreviewIds) "list-markdown" "Kuvaus" model.form.markdown MarkdownChanged
            , Form.radioGroup
                { legend = "Julkaisutila"
                , name = "list-status"
                , required = True
                , error = Nothing
                }
                { options =
                    [ { value = "draft", label = "Luonnos — vain sinä näet" }
                    , { value = "published", label = "Julkaistu — jaettavissa linkillä" }
                    ]
                , selected = statusValue model.form.status
                , onSelect = StatusChanged
                , layout = Form.Inline
                }
            , if maybeId == Nothing then
                viewEditSets model

              else
                text ""
            , div [ class "flex flex-wrap items-center gap-3 border-t border-border-default pt-5" ]
                [ sharedButton "Tallenna lista" SaveClicked Button.Primary model.saving model.saving
                , case maybeId of
                    Just _ ->
                        sharedButton "Poista lista" DeleteClicked Button.Danger model.saving False

                    Nothing ->
                        text ""
                ]
            ]
        ]


viewEditSets : Model -> Html Msg
viewEditSets model =
    section []
        [ div [ class "mb-3 flex items-center justify-between gap-3" ]
            [ h2 [ class "type-h2" ] [ text "Setit" ]
            , sharedButton "Lisää kohde" AddSet Button.Secondary False False
            ]
        , if List.isEmpty model.form.items then
            p [ class "rounded border border-border-default p-4 type-caption text-text-muted" ] [ text "Listalla ei ole vielä settejä." ]

          else
            div [ class "space-y-4" ] (List.indexedMap (viewEditSet model model.markdownPreviewIds model.form.items) model.form.items)
        ]


markdownEditor : Bool -> String -> String -> String -> (String -> Msg) -> Html Msg
markdownEditor isPreviewing id labelText markdown onChange =
    div [ class "space-y-2" ]
        [ label [ class "block type-body-small", attribute "for" id ] [ text (labelText ++ " (Markdown)") ]
        , div [ class "flex flex-wrap items-center justify-between gap-2" ]
            [ div [ class "flex flex-wrap gap-1" ]
                [ formatButton id "Lihavointi" FeatherIcons.bold "**" "**" ""
                , formatButton id "Kursivointi" FeatherIcons.italic "_" "_" ""
                , formatButton id "Linkki" FeatherIcons.link "[" "](https://example.com)" ""
                , formatButton id "Otsikko" FeatherIcons.type_ "" "" "## "
                , formatButton id "Luettelo" FeatherIcons.list "" "" "- "
                , formatButton id "Lainaus" FeatherIcons.messageSquare "" "" "> "
                ]
            , markdownPreviewButton id isPreviewing
            ]
        , div
            [ class
                (if isPreviewing then
                    "grid gap-4 md:grid-cols-2"

                 else
                    "block"
                )
            ]
            [ div [ class "min-w-0" ]
                [ textarea
                    [ attribute "id" id
                    , value markdown
                    , placeholder "Kirjoita Markdown-muodossa…"
                    , onInput onChange
                    , class (inputClass ++ " min-h-48 type-mono")
                    ]
                    []
                ]
            , if isPreviewing then
                section [ class "min-h-48 min-w-0 overflow-auto rounded border border-border-default bg-bg-subtle p-4" ]
                    [ p [ class "mb-2 type-caption text-text-muted" ] [ text "Esikatselu" ]
                    , viewMarkdownPreview markdown
                    ]

              else
                text ""
            ]
        ]


formatButton : String -> String -> FeatherIcons.Icon -> String -> String -> String -> Html Msg
formatButton id labelText icon prefix suffix linePrefix =
    Button.new { label = labelText, onClick = ApplyMarkdownFormat id prefix suffix linePrefix }
        |> Button.withVariant Button.Ghost
        |> Button.withSize Button.Small
        |> Button.withIcon icon
        |> Button.iconOnly
        |> Button.toHtml


markdownPreviewButton : String -> Bool -> Html Msg
markdownPreviewButton id isPreviewing =
    Button.new
        { label =
            if isPreviewing then
                "Piilota esikatselu"

            else
                "Näytä esikatselu"
        , onClick = ToggleMarkdownPreview id
        }
        |> Button.withVariant Button.Ghost
        |> Button.withSize Button.Small
        |> Button.withIcon
            (if isPreviewing then
                FeatherIcons.eyeOff

             else
                FeatherIcons.eye
            )
        |> Button.iconOnly
        |> Button.withPressed (Just isPreviewing)
        |> Button.toHtml


sharedButton : String -> Msg -> Button.Variant -> Bool -> Bool -> Html Msg
sharedButton labelText message variant isDisabled isLoading =
    Button.new { label = labelText, onClick = message }
        |> Button.withVariant variant
        |> Button.withDisabled isDisabled
        |> Button.withLoading isLoading
        |> Button.toHtml


iconButton : String -> FeatherIcons.Icon -> Msg -> Bool -> Html Msg
iconButton labelText icon message isDisabled =
    Button.new { label = labelText, onClick = message }
        |> Button.withVariant Button.Secondary
        |> Button.withSize Button.Small
        |> Button.withIcon icon
        |> Button.iconOnly
        |> Button.withDisabled isDisabled
        |> Button.toHtml


viewDeleteConfirmation : Bool -> Html Msg
viewDeleteConfirmation isOpen =
    div [ class "no-print" ]
        [ Dialog.view
            { title = "Poistetaanko lista?"
            , body = [ p [ class "type-body" ] [ text "Listan poistamista ei voi perua." ] ]
            , footer =
                Just
                    (div [ class "flex justify-end gap-3" ]
                        [ sharedButton "Peruuta" CancelDelete Button.Secondary False False
                        , sharedButton "Poista lista" ConfirmDelete Button.Danger False False
                        ]
                    )
            , isOpen = isOpen
            , onClose = CancelDelete
            , closeLabel = "Sulje"
            }
        ]


fieldLabel : String -> String -> Html Msg -> Html Msg
fieldLabel labelText id control =
    label [ class "block type-body-small" ]
        [ span [ class "mb-2 block" ] [ text labelText ]
        , div [ attribute "id" ("field-" ++ id) ] [ control ]
        ]


viewEditSet : Model -> List String -> List SetItem -> Int -> SetItem -> Html Msg
viewEditSet model previewIds items index item =
    section [ class "rounded-lg border border-border-default p-4" ]
        [ div [ class "flex flex-wrap items-center gap-2" ]
            [ div [ class "min-w-0 flex-1" ]
                [ Form.radioGroup
                    { legend = "Kohteen tyyppi"
                    , name = "item-kind-" ++ String.fromInt index
                    , required = False
                    , error = Nothing
                    }
                    { options =
                        [ { value = "set", label = "Setti" }
                        , { value = "altbuild", label = "Vaihtoehtoinen rakennelma" }
                        , { value = "moc", label = "MOC" }
                        ]
                    , selected = Types.itemKindToString item.kind
                    , onSelect = ItemKindChanged index
                    , layout = Form.Chips
                    }
                ]
            , iconButton "Siirrä ylemmäs" FeatherIcons.arrowUp (MoveSet index (index - 1)) (index == 0)
            , iconButton "Siirrä alemmas" FeatherIcons.arrowDown (MoveSet index (index + 1)) (index == List.length items - 1)
            , sharedButton "Poista" (RemoveSet index) Button.Danger False False
            ]
        , Form.textInput (Form.defaultField ("item-title-" ++ String.fromInt index) "Kohteen otsikko")
            { value = item.title, onInput = ItemTitleChanged index, inputType = Form.Text, placeholder = Just "Esim. Millennium Falcon" }
        , if Types.itemHasTitle item then
            text ""

          else
            p [ class "mt-1 type-caption text-red-700" ] [ text "Otsikko vaaditaan jokaiselle kohteelle." ]
        , Form.textarea (Form.defaultField ("codes-" ++ String.fromInt index) "LEGO-tunnukset (yksi tunnus rivillä)")
            { value = item.codesText, onInput = ItemCodesChanged index, rows = 3 }
        , p [ class "mt-1 type-caption text-text-muted" ] [ text "MOC-kohteelle tunnukset ovat valinnaisia. Setille ja vaihtoehtoiselle rakennelmalle vähintään yksi tunnus on pakollinen." ]
        , if Types.itemHasValidCodes item then
            text ""

          else
            p [ class "mt-1 type-caption text-red-700" ] [ text "Lisää vähintään yksi LEGO-tunnus tälle kohteelle." ]
        , viewSetLookup model index item
        , Form.textInput (Form.defaultField ("url-" ++ String.fromInt index) "Lisätietojen URL")
            { value = item.url, onInput = ItemUrlChanged index, inputType = Form.Url, placeholder = Just "https://example.com" }
        , markdownEditor
            (List.member ("item-description-" ++ String.fromInt index) previewIds)
            ("item-description-" ++ String.fromInt index)
            "Kohteen kuvaus"
            item.description
            (ItemDescriptionChanged index)
        , fieldset [ class "mt-4" ]
            [ Html.legend [ class "type-caption text-text-muted" ] [ text "Näytä linkit palveluissa" ]
            , div [ class "mt-2 flex flex-wrap gap-x-5 gap-y-2" ]
                (List.map (serviceCheckbox index item.services) [ Lego, Brickset, Bricklink, Rebrickable ])
            ]
        ]


viewSetLookup : Model -> Int -> SetItem -> Html Msg
viewSetLookup model index item =
    let
        maybeCode =
            Types.firstLookupCode item

        action provider labelText =
            Button.new { label = labelText, onClick = SetLookupClicked index provider }
                |> Button.withVariant Button.Secondary
                |> Button.withSize Button.Small
                |> Button.withDisabled (maybeCode == Nothing)
                |> Button.toHtml

        resultView state =
            case state of
                LookupLoading _ provider code ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ]
                        [ text ("Haetaan " ++ lookupProviderLabel provider ++ "-tietoja tunnukselle " ++ code ++ "…") ]

                LookupLoaded requestId _ code result ->
                    div [ attribute "aria-live" "polite", class "rounded bg-bg-subtle p-3 type-caption" ]
                        [ p [] [ text (lookupSummary result) ]
                        , div [ class "mt-2 flex flex-wrap items-center gap-3" ]
                            ([ Button.new { label = "Tallenna tiedot", onClick = AcceptLookup index requestId code }
                                |> Button.withVariant Button.Ghost
                                |> Button.withSize Button.Small
                                |> Button.toHtml
                             ]
                                ++ (case MarkdownSafety.safeWebUrl result.sourceUrl of
                                        Just sourceUrl ->
                                            [ a [ href sourceUrl, target "_blank", attribute "rel" "noopener noreferrer", class "text-brand underline" ] [ text "Avaa lähde" ] ]

                                        Nothing ->
                                            []
                                   )
                            )
                        ]

                LookupFailed _ _ _ message ->
                    p [ attribute "aria-live" "polite", class "type-caption text-brand-red" ] [ text message ]
    in
    div [ class "mt-3 space-y-2" ]
        [ div [ class "flex flex-wrap items-center gap-2" ]
            [ span [ class "type-caption text-text-muted" ] [ text "Hae setin tietoja:" ]
            , action Api.RebrickableProvider "Rebrickable"
            , action Api.BricksetProvider "Brickset"
            ]
        , case Dict.get index model.setLookups of
            Just state ->
                resultView state

            Nothing ->
                text ""
        ]


lookupProviderLabel : Api.LookupProvider -> String
lookupProviderLabel provider =
    case provider of
        Api.RebrickableProvider ->
            "Rebrickable"

        Api.BricksetProvider ->
            "Brickset"


lookupSummary : Api.SetLookupResult -> String
lookupSummary result =
    result.name
        ++ (result.year |> Maybe.map (\year -> " · " ++ String.fromInt year) |> Maybe.withDefault "")
        ++ (result.pieces |> Maybe.map (\pieces -> " · " ++ String.fromInt pieces ++ " osaa") |> Maybe.withDefault "")


serviceCheckbox : Int -> List Service -> Service -> Html Msg
serviceCheckbox index chosen service =
    label [ class "inline-flex min-h-11 items-center gap-2 type-body-small" ]
        [ input [ type_ "checkbox", checked (List.member service chosen), onCheck (ToggleService index service) ] []
        , text (Types.serviceName service)
        ]


inputClass : String
inputClass =
    "block w-full rounded border border-border-default bg-white px-3 py-2 type-body focus-visible:ring-2 focus-visible:ring-brand"
