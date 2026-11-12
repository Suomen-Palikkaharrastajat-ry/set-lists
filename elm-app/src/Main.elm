port module Main exposing (main)

{-| Hash-routed app for creating, owning, publishing, and sharing table catalogs.

i18n-exempt: Initial release exposes Finnish UI only; English is hidden in site configuration.

-}

import Api
import Browser
import Browser.Dom as Dom
import Browser.Events
import Browser.Navigation as Nav
import Component.Account as Account
import Component.Button as Button
import Component.Form as Form
import Component.Layout as Layout
import Component.Toast as Toast
import Dict exposing (Dict)
import FeatherIcons
import File
import Html exposing (Html, a, button, div, fieldset, h1, h2, h3, header, img, input, label, legend, li, main_, p, section, span, text, textarea, ul)
import Html.Attributes exposing (alt, attribute, checked, class, disabled, for, href, id, placeholder, src, style, target, type_, value)
import Html.Events exposing (on, onCheck, onClick, onInput, preventDefaultOn)
import Http
import ItemOrder
import Json.Decode as Decode
import Lang
import Markdown.Parser
import Markdown.Renderer
import MarkdownSafety
import PhotoCrop
import PocketBaseAuth exposing (AuthState(..), AuthUser, getToken)
import QRCode
import Route
import SiteSettings exposing (SiteSettings)
import Svg.Attributes as SvgA
import Task
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
    , setSearchQueries : Dict Int String
    , setSearchStates : Dict Int SetSearchState
    , activeSuggestions : Dict Int Int
    , searchRequestId : Int
    , openSetIndex : Maybe Int
    , draggingSetIndex : Maybe Int
    , dropGap : Maybe Int
    , editorTab : EditorTab
    , lookupRequestId : Int
    , markdownPreviewIds : List String
    , saving : Bool
    , photoUploadState : PhotoUploadState
    , photoSlot : String
    , photoCrop : Maybe PhotoCrop.State
    , photoFileToken : Maybe String
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


type EditorTab
    = ItemsTab
    | DescriptionTab
    | PhotosTab


type PhotoUploadState
    = PhotoReady
    | PhotoPreparing
    | PhotoCropping
    | PhotoUploading
    | PhotoRemoving
    | PhotoUploaded
    | PhotoRemoved
    | PhotoUploadFailed String


type SetSearchState
    = SetSearchWaiting Int String
    | SetSearchLoading Int String
    | SetSearchResults Int String (List Api.SetSuggestion)
    | SetSearchFailed Int String String
    | SetSearchEnriching Int String (Maybe String)
    | SetSearchEnriched Int String Bool Bool
    | SetSearchEnrichmentFailed Int String
    | SetSearchSavingThumbnail Int String Bool
    | SetSearchCodeAdded String


type alias SetSearchPayload =
    { index : Int
    , query : String
    , requestId : Int
    }


type alias SetThumbnailProcessed =
    { index : Int
    , requestId : Int
    , code : String
    , imageUrl : Maybe String
    }


type alias ListPhotoResult =
    { listId : String
    , slot : String
    , photo : String
    , fileToken : String
    , error : String
    }


type alias ListPhotoPreparedResult =
    { listId : String
    , slot : String
    , previewUrl : String
    , width : Int
    , height : Int
    , error : String
    }


type alias ListPhotoClearedResult =
    { listId : String
    , slot : String
    , error : String
    }


type alias PhotoFileTokenResult =
    { listId : String
    , token : String
    }


{-| A pointer or wheel gesture over the crop frame, in preview-frame fractions. `pan` uses `dx` and
`dy`; `zoom` uses `factor` around `x` and `y`.
-}
type alias CropGesture =
    { kind : String
    , dx : Float
    , dy : Float
    , factor : Float
    , x : Float
    , y : Float
    }


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
    | EditorEscapePressed
    | EditOnEnter
    | OAuthPopupResult { token : String, model : String }
    | LogOut
    | HomeListsLoaded String (Result Http.Error Api.ListPage)
    | ListLoaded String (Result Http.Error ListRecord)
    | TitleChanged String
    | DescriptionChanged String
    | MarkdownChanged String
    | SetSearchChanged Int String
    | SetSearchKeyPressed Int String
    | ListPhotoSelected String String
    | ListPhotoPrepared ListPhotoPreparedResult
    | PhotoCropRatioSelected PhotoCrop.CoverRatio
    | PhotoCropZoomChanged String
    | PhotoCropFocusXChanged String
    | PhotoCropFocusYChanged String
    | PhotoCropGestured CropGesture
    | PhotoCropKeyPressed String
    | PhotoCropCancelClicked
    | PhotoCropApplyClicked
    | ListPhotoProcessed ListPhotoResult
    | ListPhotoClearClicked String
    | ListPhotoCleared ListPhotoClearedResult
    | PhotoFileTokenReceived PhotoFileTokenResult
    | ItemPhotoToggled Int String Bool
    | RemoveItemCode Int String
    | SetSearchReady SetSearchPayload
    | SetSearchCompleted Int Int String (Result Http.Error (List Api.SetSuggestion))
    | SetSuggestionSelected Int Int Api.SetSuggestion
    | SetSuggestionEnriched Int Int String (Result Http.Error Api.SetLookupResult)
    | SetSuggestionThumbnailProcessed SetThumbnailProcessed
    | ItemTitleChanged Int String
    | ItemKindChanged Int String
    | ItemDescriptionChanged Int String
    | ItemUrlChanged Int String
    | ApplyMarkdownFormat String String String String
    | ToggleMarkdownPreview String
    | ToggleMenu
    | CloseMenu
    | NoOp
    | StatusChanged String
    | SelectEditorTab EditorTab
    | EditorTabKeyPressed String
    | ToggleService Int Service Bool
    | ToggleSetAccordion Int
    | SetDragStarted Int
    | SetDropGapChanged Int
    | SetDragDropped Int
    | SetDragEnded
    | AddSet
    | RemoveSet Int
    | MoveSet Int Int
    | SaveClicked
    | SaveCompleted (Result Http.Error ListRecord)
    | DeleteClicked
    | ConfirmDelete
    | CancelDelete
    | FocusDeleteDialog String
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


port scheduleSetSearch : SetSearchPayload -> Cmd msg


port setSearchReady : (SetSearchPayload -> msg) -> Sub msg


port processSetThumbnail : { index : Int, requestId : Int, code : String, imageUrl : String, pbBaseUrl : String, token : String } -> Cmd msg


port setThumbnailProcessed : (SetThumbnailProcessed -> msg) -> Sub msg


port prepareListPhoto : { inputId : String, listId : String, slot : String } -> Cmd msg


port listPhotoPrepared : (ListPhotoPreparedResult -> msg) -> Sub msg


port cancelListPhotoPreparation : { listId : String } -> Cmd msg


port applyListPhoto :
    { listId : String
    , slot : String
    , pbBaseUrl : String
    , token : String
    , crop : PhotoCrop.CropRegion
    }
    -> Cmd msg


port listPhotoProcessed : (ListPhotoResult -> msg) -> Sub msg


port clearListPhoto : { listId : String, slot : String, pbBaseUrl : String, token : String } -> Cmd msg


port listPhotoCleared : (ListPhotoClearedResult -> msg) -> Sub msg


port requestListPhotoFileToken : { listId : String, pbBaseUrl : String, token : String } -> Cmd msg


port listPhotoFileTokenReceived : (PhotoFileTokenResult -> msg) -> Sub msg


port cropGesture : (CropGesture -> msg) -> Sub msg


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
      , setSearchQueries = Dict.empty
      , setSearchStates = Dict.empty
      , activeSuggestions = Dict.empty
      , searchRequestId = 0
      , openSetIndex = Nothing
      , draggingSetIndex = Nothing
      , dropGap = Nothing
      , editorTab = ItemsTab
      , lookupRequestId = 0
      , markdownPreviewIds = []
      , saving = False
      , photoUploadState = PhotoReady
      , photoSlot = Types.coverPhotoSlot
      , photoCrop = Nothing
      , photoFileToken = Nothing
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
        , setSearchReady SetSearchReady
        , setThumbnailProcessed SetSuggestionThumbnailProcessed
        , listPhotoPrepared ListPhotoPrepared
        , listPhotoProcessed ListPhotoProcessed
        , listPhotoCleared ListPhotoCleared
        , listPhotoFileTokenReceived PhotoFileTokenReceived
        , if model.photoUploadState == PhotoCropping then
            cropGesture PhotoCropGestured

          else
            Sub.none
        , Layout.subscriptions { isOpen = model.menuOpen, onClose = CloseMenu }
        , case model.route of
            Route.EditList _ ->
                Browser.Events.onKeyDown
                    (Decode.map3
                        (\ctrlKey key targetId ->
                            if key == "Escape" && model.photoUploadState == PhotoCropping then
                                PhotoCropCancelClicked

                            else if
                                key
                                    == "Escape"
                                    && not model.confirmDelete
                                    && not model.menuOpen
                                    && not (hasActiveSetSuggestions model)
                                    && not (String.startsWith "item-search-" targetId)
                                    && not (String.startsWith "list-photo-input" targetId)
                                    && not (photoActionInProgress model.photoUploadState)
                            then
                                EditorEscapePressed

                            else if ctrlKey && key == "Enter" && not model.confirmDelete && not (photoActionInProgress model.photoUploadState) then
                                SaveClicked

                            else
                                NoOp
                        )
                        (Decode.field "ctrlKey" Decode.bool)
                        (Decode.field "key" Decode.string)
                        (Decode.oneOf [ Decode.at [ "target", "id" ] Decode.string, Decode.succeed "" ])
                    )

            Route.PublicList _ ->
                if isOwnedPublicList model && not model.menuOpen then
                    Browser.Events.onKeyDown
                        (Decode.map6
                            (\key ctrlKey altKey metaKey shiftKey targetInfo ->
                                if
                                    key
                                        == "Enter"
                                        && not ctrlKey
                                        && not altKey
                                        && not metaKey
                                        && not shiftKey
                                        && not (isInteractiveKeyTarget targetInfo.tagName targetInfo.role)
                                then
                                    EditOnEnter

                                else
                                    NoOp
                            )
                            (Decode.field "key" Decode.string)
                            (Decode.field "ctrlKey" Decode.bool)
                            (Decode.field "altKey" Decode.bool)
                            (Decode.field "metaKey" Decode.bool)
                            (Decode.field "shiftKey" Decode.bool)
                            (Decode.map2 (\tagName role -> { tagName = tagName, role = role })
                                (Decode.at [ "target", "tagName" ] Decode.string)
                                (Decode.oneOf [ Decode.at [ "target", "role" ] Decode.string, Decode.succeed "" ])
                            )
                        )

                else
                    Sub.none

            _ ->
                Sub.none
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
                ( { model | url = url, route = Route.Home, ownedLists = NotLoaded, accumulatedLists = [], currentList = NotLoaded, setSearchQueries = Dict.empty, setSearchStates = Dict.empty, activeSuggestions = Dict.empty, openSetIndex = Nothing, draggingSetIndex = Nothing, dropGap = Nothing, editorTab = ItemsTab, photoUploadState = PhotoReady, photoCrop = Nothing, photoFileToken = Nothing, confirmDelete = False, menuOpen = False }
                , Nav.pushUrl model.key "#/"
                )

            else
                ( { model | url = url, route = route, ownedLists = loaded.ownedLists, accumulatedLists = [], currentList = loaded.currentList, form = loaded.form, setSearchQueries = Dict.empty, setSearchStates = Dict.empty, activeSuggestions = Dict.empty, openSetIndex = Nothing, draggingSetIndex = Nothing, dropGap = Nothing, editorTab = ItemsTab, photoUploadState = PhotoReady, photoCrop = Nothing, photoFileToken = Nothing, confirmDelete = False, menuOpen = False }
                , Cmd.batch
                    [ loaded.cmd
                    , Task.attempt (\_ -> NoOp) (Dom.focus "main-content")
                    , if model.menuOpen then
                        Layout.onMenuClosed NoOp

                      else
                        Cmd.none
                    ]
                )

        EditorEscapePressed ->
            case model.route of
                Route.EditList (Just id) ->
                    ( model, Nav.pushUrl model.key (Route.toHref (Route.PublicList id)) )

                Route.EditList Nothing ->
                    ( model, Nav.pushUrl model.key (Route.toHref Route.Home) )

                _ ->
                    ( model, Cmd.none )

        EditOnEnter ->
            case ( model.route, model.currentList, model.auth ) of
                ( Route.PublicList listId, Loaded record, Authenticated user ) ->
                    if listId == record.id && user.id == record.owner then
                        ( model, Nav.pushUrl model.key (Route.toHref (Route.EditList (Just record.id))) )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

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
            ( { model | auth = NotAuthenticated, ownedLists = NotLoaded, notice = Nothing }
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
                            ( { model
                                | currentList = Loaded record
                                , form = form
                                , photoFileToken = Nothing
                                , openSetIndex = Nothing
                                , draggingSetIndex = Nothing
                                , dropGap = Nothing
                              }
                            , case getToken model.auth of
                                Just token ->
                                    if Dict.isEmpty record.savedPhotos then
                                        Cmd.none

                                    else
                                        requestListPhotoFileToken { listId = record.id, pbBaseUrl = model.pbBaseUrl, token = token }

                                Nothing ->
                                    Cmd.none
                            )

                    Err error ->
                        ( { model | currentList = LoadFailed (httpError error) }, Cmd.none )

            else
                ( model, Cmd.none )

        ListPhotoSelected slot listId ->
            case ( model.route, model.currentList, getToken model.auth ) of
                ( Route.EditList (Just routeId), Loaded record, Just _ ) ->
                    if routeId /= listId || record.id /= listId || not (List.member slot Types.photoSlots) || photoActionInProgress model.photoUploadState then
                        ( model, Cmd.none )

                    else
                        ( { model | photoUploadState = PhotoPreparing, photoSlot = slot }
                        , prepareListPhoto
                            { inputId = photoInputId slot
                            , listId = listId
                            , slot = slot
                            }
                        )

                _ ->
                    ( model, Cmd.none )

        ListPhotoPrepared result ->
            case ( model.route, model.currentList ) of
                ( Route.EditList (Just routeId), Loaded record ) ->
                    if routeId /= result.listId || record.id /= result.listId || result.slot /= model.photoSlot || model.photoUploadState /= PhotoPreparing then
                        ( model, Cmd.none )

                    else if result.error /= "" then
                        ( { model | photoUploadState = PhotoUploadFailed (photoUploadErrorMessage result.error) }, Cmd.none )

                    else
                        ( { model
                            | photoCrop = Just (PhotoCrop.initialState result.listId result.previewUrl result.width result.height)
                            , photoUploadState = PhotoCropping
                          }
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        PhotoCropRatioSelected ratio ->
            updatePhotoCrop model (\crop -> { crop | ratio = ratio })

        PhotoCropZoomChanged value ->
            updatePhotoCrop model (\crop -> { crop | zoom = String.toFloat value |> Maybe.withDefault crop.zoom })

        PhotoCropFocusXChanged value ->
            updatePhotoCrop model (\crop -> { crop | focusX = String.toFloat value |> Maybe.withDefault crop.focusX })

        PhotoCropFocusYChanged value ->
            updatePhotoCrop model (\crop -> { crop | focusY = String.toFloat value |> Maybe.withDefault crop.focusY })

        PhotoCropGestured gesture ->
            if gesture.kind == "pan" then
                updatePhotoCrop model (PhotoCrop.panBy gesture.dx gesture.dy)

            else if gesture.kind == "zoom" then
                updatePhotoCrop model (PhotoCrop.zoomAt gesture.factor gesture.x gesture.y)

            else
                ( model, Cmd.none )

        PhotoCropKeyPressed key ->
            case photoCropKey key of
                Just (CropPan dx dy) ->
                    updatePhotoCrop model (PhotoCrop.panBy dx dy)

                Just (CropZoom factor) ->
                    updatePhotoCrop model (PhotoCrop.zoomAt factor 0.5 0.5)

                Nothing ->
                    ( model, Cmd.none )

        PhotoCropCancelClicked ->
            case model.photoCrop of
                Just crop ->
                    if model.photoUploadState == PhotoCropping then
                        ( { model | photoCrop = Nothing, photoUploadState = PhotoReady }
                        , cancelListPhotoPreparation { listId = crop.listId }
                        )

                    else
                        ( model, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        PhotoCropApplyClicked ->
            case ( model.route, model.currentList ) of
                ( Route.EditList (Just routeId), Loaded record ) ->
                    case ( model.photoCrop, getToken model.auth ) of
                        ( Just crop, Just token ) ->
                            if routeId /= record.id || record.id /= crop.listId || model.photoUploadState /= PhotoCropping then
                                ( model, Cmd.none )

                            else
                                ( { model | photoCrop = Nothing, photoUploadState = PhotoUploading }
                                , applyListPhoto
                                    { listId = record.id
                                    , slot = model.photoSlot
                                    , pbBaseUrl = model.pbBaseUrl
                                    , token = token
                                    , crop = PhotoCrop.cropRegion crop
                                    }
                                )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        ListPhotoProcessed result ->
            case ( model.route, model.currentList ) of
                ( Route.EditList (Just routeId), Loaded record ) ->
                    if routeId /= result.listId || record.id /= result.listId || result.slot /= model.photoSlot then
                        ( model, Cmd.none )

                    else if result.error /= "" then
                        ( { model | photoUploadState = PhotoUploadFailed (photoUploadErrorMessage result.error) }, Cmd.none )

                    else
                        ( { model
                            | currentList = Loaded (Types.setSavedPhoto result.slot (nonEmptyPhoto result.photo) record)
                            , photoUploadState = PhotoUploaded
                            , photoFileToken =
                                case nonEmptyPhoto result.fileToken of
                                    Just token ->
                                        Just token

                                    Nothing ->
                                        model.photoFileToken
                          }
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        ListPhotoClearClicked slot ->
            case ( model.route, model.currentList, getToken model.auth ) of
                ( Route.EditList (Just routeId), Loaded record, Just token ) ->
                    if routeId /= record.id || Types.savedPhotoFilename slot record == Nothing || photoActionInProgress model.photoUploadState then
                        ( model, Cmd.none )

                    else
                        ( { model | photoUploadState = PhotoRemoving, photoSlot = slot }
                        , clearListPhoto { listId = record.id, slot = slot, pbBaseUrl = model.pbBaseUrl, token = token }
                        )

                _ ->
                    ( model, Cmd.none )

        ListPhotoCleared result ->
            case ( model.route, model.currentList ) of
                ( Route.EditList (Just routeId), Loaded record ) ->
                    if routeId /= result.listId || record.id /= result.listId || result.slot /= model.photoSlot then
                        ( model, Cmd.none )

                    else if result.error /= "" then
                        ( { model | photoUploadState = PhotoUploadFailed "Kuvan poistaminen epäonnistui. Yritä uudelleen." }, Cmd.none )

                    else
                        let
                            updated =
                                Types.setSavedPhoto result.slot Nothing record
                        in
                        ( mapForm (\form -> { form | items = Types.clearPhotoSlotFromItems result.slot form.items })
                            { model
                                | currentList = Loaded { updated | items = Types.clearPhotoSlotFromItems result.slot updated.items }
                                , photoFileToken =
                                    if Dict.isEmpty updated.savedPhotos then
                                        Nothing

                                    else
                                        model.photoFileToken
                                , photoUploadState = PhotoRemoved
                            }
                        , Cmd.none
                        )

                _ ->
                    ( model, Cmd.none )

        PhotoFileTokenReceived result ->
            case ( model.route, model.currentList ) of
                ( Route.PublicList routeId, Loaded record ) ->
                    if routeId == result.listId && record.id == result.listId && result.token /= "" then
                        ( { model | photoFileToken = Just result.token }, Cmd.none )

                    else
                        ( model, Cmd.none )

                ( Route.EditList (Just routeId), Loaded record ) ->
                    if routeId == result.listId && record.id == result.listId && result.token /= "" then
                        ( { model | photoFileToken = Just result.token }, Cmd.none )

                    else
                        ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        TitleChanged title ->
            ( mapForm (\form -> { form | title = title }) model, Cmd.none )

        DescriptionChanged description ->
            ( mapForm (\form -> { form | description = description }) model, Cmd.none )

        MarkdownChanged markdown ->
            ( mapForm (\form -> { form | markdown = markdown }) model, Cmd.none )

        SetSearchChanged index query ->
            let
                requestId =
                    model.searchRequestId + 1

                trimmedQuery =
                    String.trim query

                updated =
                    { model
                        | setSearchQueries = Dict.insert index query model.setSearchQueries
                        , activeSuggestions = Dict.remove index model.activeSuggestions
                        , searchRequestId = requestId
                    }
            in
            if String.length trimmedQuery < 2 then
                ( { updated | setSearchStates = Dict.remove index model.setSearchStates }, Cmd.none )

            else
                let
                    payload =
                        { index = index, query = trimmedQuery, requestId = requestId }
                in
                ( { updated | setSearchStates = Dict.insert index (SetSearchWaiting requestId trimmedQuery) model.setSearchStates }
                , scheduleSetSearch payload
                )

        SetSearchKeyPressed index key ->
            case Dict.get index model.setSearchStates of
                Just (SetSearchResults requestId _ suggestions) ->
                    let
                        activeIndex =
                            Dict.get index model.activeSuggestions |> Maybe.withDefault 0

                        lastIndex =
                            max 0 (List.length suggestions - 1)
                    in
                    case key of
                        "ArrowDown" ->
                            ( { model | activeSuggestions = Dict.insert index (min lastIndex (activeIndex + 1)) model.activeSuggestions }, Cmd.none )

                        "ArrowUp" ->
                            ( { model | activeSuggestions = Dict.insert index (max 0 (activeIndex - 1)) model.activeSuggestions }, Cmd.none )

                        "Enter" ->
                            List.drop activeIndex suggestions
                                |> List.head
                                |> Maybe.map (SetSuggestionSelected index requestId >> (\selectionMsg -> update selectionMsg model))
                                |> Maybe.withDefault ( model, Cmd.none )

                        "Escape" ->
                            ( { model
                                | setSearchQueries = Dict.insert index "" model.setSearchQueries
                                , setSearchStates = Dict.remove index model.setSearchStates
                                , activeSuggestions = Dict.remove index model.activeSuggestions
                              }
                            , Cmd.none
                            )

                        _ ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        SetSearchReady payload ->
            case Dict.get payload.index model.setSearchStates of
                Just (SetSearchWaiting activeId activeQuery) ->
                    if activeId /= payload.requestId || activeQuery /= payload.query then
                        ( model, Cmd.none )

                    else
                        case getToken model.auth of
                            Just token ->
                                ( { model | setSearchStates = Dict.insert payload.index (SetSearchLoading activeId activeQuery) model.setSearchStates }
                                , Api.searchSetSuggestions model.pbBaseUrl token activeQuery (SetSearchCompleted payload.index activeId activeQuery)
                                )

                            Nothing ->
                                ( { model | setSearchStates = Dict.insert payload.index (SetSearchFailed activeId activeQuery "Kirjaudu sisään käyttääksesi hakua.") model.setSearchStates }
                                , Cmd.none
                                )

                _ ->
                    ( model, Cmd.none )

        SetSearchCompleted index requestId query result ->
            case Dict.get index model.setSearchStates of
                Just (SetSearchLoading activeId activeQuery) ->
                    if activeId /= requestId || activeQuery /= query then
                        ( model, Cmd.none )

                    else
                        case result of
                            Ok suggestions ->
                                ( { model
                                    | setSearchStates = Dict.insert index (SetSearchResults requestId query suggestions) model.setSearchStates
                                    , activeSuggestions =
                                        if List.isEmpty suggestions then
                                            Dict.remove index model.activeSuggestions

                                        else
                                            Dict.insert index 0 model.activeSuggestions
                                  }
                                , Cmd.none
                                )

                            Err error ->
                                ( { model | setSearchStates = Dict.insert index (SetSearchFailed requestId query ("Settien haku ei onnistunut (" ++ httpError error ++ ").")) model.setSearchStates }
                                , Cmd.none
                                )

                _ ->
                    ( model, Cmd.none )

        SetSuggestionSelected index requestId suggestion ->
            let
                isCurrentSuggestion =
                    case Dict.get index model.setSearchStates of
                        Just (SetSearchResults activeId _ suggestions) ->
                            activeId == requestId && List.any (.code >> (==) suggestion.code) suggestions

                        _ ->
                            False

                maybeCurrentItem =
                    List.drop index model.form.items |> List.head
            in
            if not isCurrentSuggestion || not (Types.validSetCode suggestion.code) then
                ( model, Cmd.none )

            else
                let
                    codeAlreadyPresent =
                        maybeCurrentItem |> Maybe.map (.codes >> List.member suggestion.code) |> Maybe.withDefault False

                    needsMetadataLookup =
                        not codeAlreadyPresent
                            && (maybeCurrentItem |> Maybe.andThen Types.firstLookupCode |> Maybe.withDefault "")
                            == ""

                    itemWithSuggestion item =
                        let
                            selectedItem =
                                if List.member suggestion.code item.codes then
                                    item

                                else
                                    let
                                        codes =
                                            item.codes ++ [ suggestion.code ]
                                    in
                                    { item
                                        | title = Types.fillTitleFromLookup item.title suggestion.name
                                        , codes = codes
                                        , codesText = String.join "\n" codes
                                    }
                        in
                        if needsMetadataLookup then
                            Types.acceptCatalog
                                { provider = Types.RebrickableCatalog
                                , code = suggestion.code
                                , name = suggestion.name
                                , year = suggestion.year
                                , pieces = suggestion.pieces
                                , imageUrl = Nothing
                                }
                                selectedItem

                        else
                            selectedItem

                    updated =
                        mapForm (\form -> { form | items = updateAt index itemWithSuggestion form.items }) model

                    enrichmentRequestId =
                        model.lookupRequestId + 1

                    updatedWithSearch =
                        { updated
                            | setSearchQueries = Dict.insert index "" model.setSearchQueries
                            , activeSuggestions = Dict.remove index model.activeSuggestions
                            , setSearchStates =
                                if codeAlreadyPresent then
                                    Dict.insert index (SetSearchCodeAdded "Tunnus on jo listassa.") model.setSearchStates

                                else if needsMetadataLookup then
                                    Dict.insert index (SetSearchEnriching enrichmentRequestId suggestion.code suggestion.imageUrl) model.setSearchStates

                                else
                                    Dict.insert index (SetSearchCodeAdded "Tunnus lisättiin listaan.") model.setSearchStates
                        }
                in
                if not needsMetadataLookup then
                    ( updatedWithSearch, Task.attempt (\_ -> NoOp) (Dom.focus ("item-search-" ++ String.fromInt index)) )

                else
                    case getToken model.auth of
                        Just token ->
                            ( { updatedWithSearch | lookupRequestId = enrichmentRequestId, setSearchStates = Dict.insert index (SetSearchEnriching enrichmentRequestId suggestion.code suggestion.imageUrl) updatedWithSearch.setSearchStates }
                            , Cmd.batch
                                [ Api.lookupSet model.pbBaseUrl token Api.BricksetProvider suggestion.code (SetSuggestionEnriched index enrichmentRequestId suggestion.code)
                                , Task.attempt (\_ -> NoOp) (Dom.focus ("item-search-" ++ String.fromInt index))
                                ]
                            )

                        Nothing ->
                            ( { updatedWithSearch | lookupRequestId = enrichmentRequestId, setSearchStates = Dict.insert index (SetSearchEnrichmentFailed enrichmentRequestId suggestion.code) updatedWithSearch.setSearchStates }
                            , Task.attempt (\_ -> NoOp) (Dom.focus ("item-search-" ++ String.fromInt index))
                            )

        SetSuggestionEnriched index requestId code result ->
            case Dict.get index model.setSearchStates of
                Just (SetSearchEnriching activeId activeCode rebrickableImageUrl) ->
                    if activeId /= requestId || activeCode /= code then
                        ( model, Cmd.none )

                    else
                        case result of
                            Ok lookupResult ->
                                let
                                    updatedForm =
                                        model.form

                                    bricksetCatalog =
                                        { provider = Types.BricksetCatalog
                                        , code = code
                                        , name = lookupResult.name
                                        , year = lookupResult.year
                                        , pieces = lookupResult.pieces
                                        , imageUrl = Nothing
                                        }

                                    updated =
                                        { model
                                            | form = { updatedForm | items = updateAt index (Types.acceptCatalog bricksetCatalog) updatedForm.items }
                                        }

                                    imageSource =
                                        case rebrickableImageUrl of
                                            Just url ->
                                                Just url

                                            Nothing ->
                                                lookupResult.imageUrl
                                in
                                case ( imageSource, getToken model.auth ) of
                                    ( Just sourceUrl, Just token ) ->
                                        ( { updated | setSearchStates = Dict.insert index (SetSearchSavingThumbnail requestId code True) model.setSearchStates }
                                        , processSetThumbnail
                                            { index = index
                                            , requestId = requestId
                                            , code = code
                                            , imageUrl = sourceUrl
                                            , pbBaseUrl = model.pbBaseUrl
                                            , token = token
                                            }
                                        )

                                    _ ->
                                        ( { updated | setSearchStates = Dict.insert index (SetSearchEnriched requestId code True False) model.setSearchStates }
                                        , Cmd.none
                                        )

                            Err _ ->
                                case ( rebrickableImageUrl, getToken model.auth ) of
                                    ( Just sourceUrl, Just token ) ->
                                        ( { model | setSearchStates = Dict.insert index (SetSearchSavingThumbnail requestId code False) model.setSearchStates }
                                        , processSetThumbnail
                                            { index = index
                                            , requestId = requestId
                                            , code = code
                                            , imageUrl = sourceUrl
                                            , pbBaseUrl = model.pbBaseUrl
                                            , token = token
                                            }
                                        )

                                    _ ->
                                        ( { model | setSearchStates = Dict.insert index (SetSearchEnrichmentFailed requestId code) model.setSearchStates }
                                        , Cmd.none
                                        )

                _ ->
                    ( model, Cmd.none )

        SetSuggestionThumbnailProcessed processed ->
            case Dict.get processed.index model.setSearchStates of
                Just (SetSearchSavingThumbnail activeId activeCode hasBricksetMetadata) ->
                    if activeId /= processed.requestId || activeCode /= processed.code then
                        ( model, Cmd.none )

                    else if not (List.drop processed.index model.form.items |> List.head |> Maybe.map (Types.lookupCodeMatches processed.code) |> Maybe.withDefault False) then
                        ( model, Cmd.none )

                    else
                        case processed.imageUrl of
                            Just imageUrl ->
                                let
                                    currentForm =
                                        model.form

                                    attachThumbnail item =
                                        case item.catalog of
                                            Just catalog ->
                                                if catalog.code == processed.code then
                                                    { item | catalog = Just { catalog | imageUrl = Just imageUrl } }

                                                else
                                                    item

                                            Nothing ->
                                                item
                                in
                                ( { model
                                    | form = { currentForm | items = updateAt processed.index attachThumbnail currentForm.items }
                                    , setSearchStates = Dict.insert processed.index (SetSearchEnriched processed.requestId processed.code hasBricksetMetadata True) model.setSearchStates
                                  }
                                , Cmd.none
                                )

                            Nothing ->
                                ( { model | setSearchStates = Dict.insert processed.index (SetSearchEnriched processed.requestId processed.code hasBricksetMetadata False) model.setSearchStates }
                                , Cmd.none
                                )

                _ ->
                    ( model, Cmd.none )

        ItemTitleChanged index title ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | title = title }) form.items }) model, Cmd.none )

        RemoveItemCode index code ->
            let
                updated =
                    mapForm
                        (\form ->
                            { form
                                | items =
                                    updateAt index
                                        (\item -> Types.setItemCodesText (item.codes |> List.filter ((/=) code) |> String.join "\n") item)
                                        form.items
                            }
                        )
                        model
            in
            ( { updated
                | setSearchQueries = Dict.insert index "" updated.setSearchQueries
                , setSearchStates = Dict.remove index updated.setSearchStates
                , activeSuggestions = Dict.remove index updated.activeSuggestions
              }
            , Task.attempt (\_ -> NoOp) (Dom.focus ("item-search-" ++ String.fromInt index))
            )

        ItemKindChanged index kind ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | kind = Types.itemKindFromString kind }) form.items }) model, Cmd.none )

        ItemDescriptionChanged index description ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | description = description }) form.items }) model, Cmd.none )

        ItemUrlChanged index url ->
            ( mapForm (\form -> { form | items = updateAt index (\item -> { item | url = url }) form.items }) model, Cmd.none )

        ItemPhotoToggled index slot enabled ->
            let
                toggle item =
                    { item
                        | photos =
                            Types.normalizePhotoSlots
                                (if enabled then
                                    slot :: item.photos

                                 else
                                    List.filter ((/=) slot) item.photos
                                )
                    }
            in
            ( mapForm (\form -> { form | items = updateAt index toggle form.items }) model, Cmd.none )

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

        SelectEditorTab tab ->
            ( { model | editorTab = tab }, refreshPhotoFileToken model )

        EditorTabKeyPressed key ->
            let
                nextTab =
                    editorTabForKey model.editorTab key
            in
            if nextTab == model.editorTab then
                ( model, Cmd.none )

            else
                ( { model | editorTab = nextTab }
                , Cmd.batch
                    [ Task.attempt (\_ -> NoOp) (Dom.focus (editorTabId nextTab))
                    , refreshPhotoFileToken model
                    ]
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

        ToggleSetAccordion index ->
            ( { model
                | openSetIndex =
                    if model.openSetIndex == Just index then
                        Nothing

                    else
                        Just index
              }
            , Cmd.none
            )

        SetDragStarted index ->
            ( { model | draggingSetIndex = Just index, dropGap = Nothing }, Cmd.none )

        SetDropGapChanged gap ->
            case model.draggingSetIndex of
                Just _ ->
                    ( { model | dropGap = Just gap }, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        SetDragDropped gap ->
            case model.draggingSetIndex of
                Just fromIndex ->
                    let
                        count =
                            List.length model.form.items

                        cleared =
                            { model | draggingSetIndex = Nothing, dropGap = Nothing }
                    in
                    if fromIndex < 0 || fromIndex >= count || gap < 0 || gap > count || ItemOrder.targetIndex fromIndex gap == fromIndex then
                        ( cleared, Cmd.none )

                    else
                        update (MoveSet fromIndex (ItemOrder.targetIndex fromIndex gap)) cleared

                Nothing ->
                    ( model, Cmd.none )

        SetDragEnded ->
            ( { model | draggingSetIndex = Nothing, dropGap = Nothing }, Cmd.none )

        AddSet ->
            let
                newIndex =
                    List.length model.form.items

                updated =
                    mapForm (\form -> { form | items = form.items ++ [ Types.emptySetItem ] }) model
            in
            ( { updated
                | setSearchQueries = Dict.insert newIndex "" model.setSearchQueries
                , setSearchStates = Dict.remove newIndex model.setSearchStates
                , activeSuggestions = Dict.remove newIndex model.activeSuggestions
                , openSetIndex = Just newIndex
                , editorTab = ItemsTab
              }
            , Task.attempt (\_ -> NoOp) (Dom.focus ("item-search-" ++ String.fromInt newIndex))
            )

        RemoveSet index ->
            let
                remainingItems =
                    List.indexedMap Tuple.pair model.form.items
                        |> List.filter (Tuple.first >> (/=) index)
                        |> List.map Tuple.second

                updated =
                    mapForm (\form -> { form | items = remainingItems }) model

                nextOpenIndex =
                    case model.openSetIndex of
                        Nothing ->
                            Nothing

                        Just openIndex ->
                            if List.isEmpty remainingItems then
                                Nothing

                            else if openIndex == index then
                                Just (min index (List.length remainingItems - 1))

                            else if openIndex > index then
                                Just (openIndex - 1)

                            else
                                Just openIndex
            in
            ( { updated | setSearchQueries = Dict.empty, setSearchStates = Dict.empty, activeSuggestions = Dict.empty, openSetIndex = nextOpenIndex }
            , Task.attempt (\_ -> NoOp)
                (Dom.focus
                    (if List.isEmpty remainingItems then
                        editorTabId ItemsTab

                     else
                        "edit-set-toggle-" ++ String.fromInt (min index (List.length remainingItems - 1))
                    )
                )
            )

        MoveSet from to ->
            let
                updated =
                    mapForm (\form -> { form | items = ItemOrder.moveItem from to form.items }) model
            in
            ( { updated | setSearchQueries = Dict.empty, setSearchStates = Dict.empty, activeSuggestions = Dict.empty, openSetIndex = moveOpenSetIndex from to model.openSetIndex }, Cmd.none )

        SaveClicked ->
            case ( getToken model.auth, model.auth, model.route ) of
                ( Just token, Authenticated user, Route.EditList maybeId ) ->
                    if model.saving || photoActionInProgress model.photoUploadState then
                        ( model, Cmd.none )

                    else if String.trim model.form.title == "" then
                        ( { model | notice = Just "Anna listalle otsikko ennen tallentamista." }, Cmd.none )

                    else if List.any (Types.itemHasTitle >> not) model.form.items then
                        ( { model | notice = Just "Anna jokaiselle kohteelle otsikko ennen tallentamista." }, Cmd.none )

                    else if List.any (Types.itemHasValidCodes >> not) model.form.items then
                        ( { model | notice = Just "Lisää vähintään yksi tunnus jokaiselle setille ja vaihtoehtoiselle rakennelmalle ennen tallentamista." }, Cmd.none )

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
                    if photoActionInProgress model.photoUploadState then
                        ( model, Cmd.none )

                    else
                        ( { model | confirmDelete = True }, Task.attempt (\_ -> NoOp) (Dom.focus "delete-dialog-cancel") )

                _ ->
                    ( model, Cmd.none )

        ConfirmDelete ->
            case ( getToken model.auth, model.route ) of
                ( Just token, Route.EditList (Just id) ) ->
                    ( { model | saving = True, confirmDelete = False }
                    , Cmd.batch
                        [ Api.deleteList model.pbBaseUrl token id DeleteCompleted
                        , Task.attempt (\_ -> NoOp) (Dom.focus "delete-list-button")
                        ]
                    )

                _ ->
                    ( model, Cmd.none )

        CancelDelete ->
            ( { model | confirmDelete = False }, Task.attempt (\_ -> NoOp) (Dom.focus "delete-list-button") )

        FocusDeleteDialog targetId ->
            ( model, Task.attempt (\_ -> NoOp) (Dom.focus targetId) )

        DeleteCompleted result ->
            case result of
                Ok _ ->
                    ( { model | saving = False, confirmDelete = False, notice = Just "Lista poistettiin." }, Nav.pushUrl model.key "#/" )

                Err error ->
                    ( { model | saving = False, confirmDelete = False, notice = Just ("Poisto epäonnistui: " ++ httpError error) }
                    , Task.attempt (\_ -> NoOp) (Dom.focus "delete-list-button")
                    )

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


moveOpenSetIndex : Int -> Int -> Maybe Int -> Maybe Int
moveOpenSetIndex from to maybeOpenIndex =
    Maybe.map
        (\openIndex ->
            if openIndex == from then
                to

            else if from < to && openIndex > from && openIndex <= to then
                openIndex - 1

            else if to < from && openIndex >= to && openIndex < from then
                openIndex + 1

            else
                openIndex
        )
        maybeOpenIndex


editorTabOrder : List EditorTab
editorTabOrder =
    [ ItemsTab, DescriptionTab, PhotosTab ]


editorTabForKey : EditorTab -> String -> EditorTab
editorTabForKey activeTab key =
    let
        lastIndex =
            List.length editorTabOrder - 1

        activeIndex =
            editorTabOrder
                |> List.indexedMap Tuple.pair
                |> List.filter (\( _, tab ) -> tab == activeTab)
                |> List.head
                |> Maybe.map Tuple.first
                |> Maybe.withDefault 0

        tabAt index =
            List.drop index editorTabOrder |> List.head |> Maybe.withDefault activeTab
    in
    case key of
        "ArrowLeft" ->
            tabAt
                (if activeIndex == 0 then
                    lastIndex

                 else
                    activeIndex - 1
                )

        "ArrowRight" ->
            tabAt
                (if activeIndex == lastIndex then
                    0

                 else
                    activeIndex + 1
                )

        "Home" ->
            ItemsTab

        "End" ->
            PhotosTab

        _ ->
            activeTab


editorTabId : EditorTab -> String
editorTabId tab =
    case tab of
        ItemsTab ->
            "editor-tab-items"

        DescriptionTab ->
            "editor-tab-description"

        PhotosTab ->
            "editor-tab-photos"


editorPanelId : EditorTab -> String
editorPanelId tab =
    case tab of
        ItemsTab ->
            "editor-panel-items"

        DescriptionTab ->
            "editor-panel-description"

        PhotosTab ->
            "editor-panel-photos"


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
    { title = "Palikkaesitteet"
    , body =
        Layout.view
            { site = model.site
            , strings = UiStrings.forLang model.lang
            , attributes =
                [ class "min-h-screen flex flex-col bg-bg-page text-text-primary" ]
                    ++ (if model.confirmDelete then
                            [ attribute "inert" "" ]

                        else
                            []
                       )
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
                    main_ [ attribute "id" "main-content", attribute "tabindex" "-1", class "w-full flex-1" ]
                        [ viewAnonymousBrandBar model
                        , div [ class "mx-auto w-full max-w-5xl px-3 py-4 sm:px-4 sm:py-8" ] [ viewPage model ]
                        ]

                else
                    main_ [ attribute "id" "main-content", attribute "tabindex" "-1", class "mx-auto w-full max-w-5xl flex-1 px-4 py-8" ] [ viewPage model ]
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
                [ h1 [ class "type-h1" ] [ text "Luo ja jaa pöytäesitteitä" ]
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
                        , p [ class "type-body mt-2 text-text-muted" ] [ text "Hallinnoi luonnoksia ja jaettuja pöytäesitteitä." ]
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
            [ Button.link { label = "Avaa", href = Route.toHref (Route.PublicList record.id) }
                |> Button.withVariant Button.Primary
                |> Button.withSize Button.Small
                |> Button.toHtml
            , Button.link { label = "Muokkaa", href = Route.toHref (Route.EditList (Just record.id)) }
                |> Button.withVariant Button.Secondary
                |> Button.withSize Button.Small
                |> Button.toHtml
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
                viewListDetail model owned record

        NotLoaded ->
            text ""


isAuthenticated : AuthState -> Bool
isAuthenticated auth =
    case auth of
        Authenticated _ ->
            True

        NotAuthenticated ->
            False


isOwnedPublicList : Model -> Bool
isOwnedPublicList model =
    case ( model.route, model.currentList, model.auth ) of
        ( Route.PublicList listId, Loaded record, Authenticated user ) ->
            listId == record.id && user.id == record.owner

        _ ->
            False


isInteractiveKeyTarget : String -> String -> Bool
isInteractiveKeyTarget tagName role =
    List.member (String.toUpper tagName) [ "A", "BUTTON", "INPUT", "TEXTAREA", "SELECT", "OPTION", "SUMMARY" ]
        || List.member (String.toLower role) [ "button", "link", "tab", "menuitem", "option", "combobox" ]


hasActiveSetSuggestions : Model -> Bool
hasActiveSetSuggestions model =
    model.editorTab
        == ItemsTab
        && (model.openSetIndex
                |> Maybe.map (\index -> Dict.member index model.activeSuggestions)
                |> Maybe.withDefault False
           )


viewListDetail : Model -> Bool -> ListRecord -> Html Msg
viewListDetail model owned record =
    let
        authenticated =
            isAuthenticated model.auth

        catalogsByCode =
            record.items
                |> List.filterMap .catalog
                |> List.foldl (\catalog catalogs -> Dict.insert catalog.code catalog catalogs) Dict.empty

        galleryUrls =
            Types.galleryPhotoSlots
                |> List.filterMap (\slot -> savedPhotoUrlForModel model record slot |> Maybe.map (\url -> ( slot, url )))
                |> Dict.fromList

        containerClass =
            if authenticated then
                "print-list mx-auto max-w-3xl bg-white p-0 sm:rounded-lg sm:border sm:border-border-default sm:p-8 sm:shadow-sm"

            else
                "print-list anonymous-list mx-auto max-w-3xl bg-white p-0 sm:p-2"

        itemsClass =
            if authenticated then
                "mt-7 divide-y divide-border-default print-items"

            else
                "mt-5 print-items"
    in
    section [ class containerClass ]
        [ if record.status == Published then
            viewPrintQr record.id

          else
            text ""
        , if authenticated then
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
        , div [ class "print-title-page" ]
            [ div [ class "print-title flex flex-wrap items-start justify-between gap-4" ]
                ([ div [ class "min-w-0 flex-1 flow-root" ]
                    [ viewListPhoto model record
                    , h1 [ class "type-h1" ] [ text record.title ]
                    , if String.trim record.description == "" then
                        text ""

                      else
                        p [ class "type-body text-text-muted" ] [ text (String.trim record.description) ]
                    , viewMarkdown record.markdown
                    ]
                 ]
                    ++ (if authenticated then
                            [ div [ class "no-print" ] [ statusBadge record.status ] ]

                        else
                            []
                       )
                )
            ]
        , div [ class itemsClass ] (List.indexedMap (viewSet catalogsByCode galleryUrls) record.items)
        ]


nonEmptyPhoto : String -> Maybe String
nonEmptyPhoto filename =
    if String.trim filename == "" then
        Nothing

    else
        Just filename


savedPhotoUrlForModel : Model -> ListRecord -> String -> Maybe String
savedPhotoUrlForModel model record slot =
    if record.status == Draft && model.photoFileToken == Nothing then
        Nothing

    else
        Api.photoUrl model.pbBaseUrl model.photoFileToken record slot


viewListPhoto : Model -> ListRecord -> Html Msg
viewListPhoto model record =
    case savedPhotoUrlForModel model record Types.coverPhotoSlot of
        Just imageUrl ->
            img
                [ src imageUrl
                , alt ("Kansikuva: " ++ record.title)
                , attribute "loading" "eager"
                , attribute "referrerpolicy" "no-referrer"
                , class "float-left mr-4 mb-3 h-32 w-32 rounded object-contain object-top pt-2"
                ]
                []

        Nothing ->
            text ""


viewSet : Dict String Types.SetCatalog -> Dict String String -> Int -> SetItem -> Html Msg
viewSet catalogsByCode galleryUrls index item =
    section [ class "print-break flex flex-wrap items-baseline gap-4 py-4" ]
        [ span [ class "type-mono text-text-muted" ] [ text (String.fromInt (index + 1) ++ ".") ]
        , div [ class "min-w-0 flex-1" ]
            [ div [ class "flow-root" ]
                [ viewItemThumbnails "hidden sm:float-right sm:mb-3 sm:ml-4 sm:flex sm:max-w-[45%] sm:flex-wrap sm:justify-end sm:gap-2" catalogsByCode galleryUrls item
                , div [ class "mb-2" ]
                    [ h2 [ class "inline type-h3 break-words [overflow-wrap:anywhere]" ]
                        [ text
                            (if String.trim item.title == "" then
                                itemKindName item.kind

                             else
                                item.title
                            )
                        ]
                    , case item.kind of
                        AltBuild ->
                            span [ class "ml-2 inline-flex items-center rounded bg-bg-subtle px-2 py-0.5 type-caption text-text-muted" ] [ text "ALT" ]

                        Moc ->
                            span [ class "ml-2 inline-flex items-center rounded bg-bg-subtle px-2 py-0.5 type-caption text-text-muted" ] [ text "MOC" ]

                        Set ->
                            text ""
                    , case MarkdownSafety.safeWebUrl item.url of
                        Just safeUrl ->
                            a [ href safeUrl, target "_blank", attribute "rel" "noopener noreferrer", class "ml-3 inline-block text-brand underline" ] [ text "Lisätietoja" ]

                        Nothing ->
                            text ""
                    ]
                , viewItemThumbnails "float-left mr-4 mb-3 flex w-32 max-w-[45%] flex-col gap-2 sm:hidden" catalogsByCode galleryUrls item
                , viewItemMarkdown item.description
                ]
            , if List.isEmpty item.codes then
                if item.kind == Moc then
                    text ""

                else
                    p [ class "mt-2 type-caption text-text-muted" ] [ text "Ei setin tunnuksia" ]

              else
                div [ class "mt-3 space-y-3" ] (List.map (viewCodeLinks item.services catalogsByCode) item.codes)
            ]
        ]


viewItemPhotoChoices : Model -> Int -> SetItem -> Html Msg
viewItemPhotoChoices model index item =
    fieldset [ class "mt-4 space-y-2" ]
        [ Html.legend [ class "type-caption text-text-muted" ] [ text "Näytä galleriakuvat" ]
        , if savedListRecord model == Nothing then
            p [ class "type-caption text-text-muted" ] [ text "Tallenna lista ja lisää galleriakuvat, jotta ne voi valita tähän kohteeseen." ]

          else
            text ""
        , div [ class "flex flex-wrap gap-x-5 gap-y-2" ]
            (List.indexedMap (viewItemPhotoChoice model index item) Types.galleryPhotoSlots)
        ]


viewItemPhotoChoice : Model -> Int -> SetItem -> Int -> String -> Html Msg
viewItemPhotoChoice model index item position slot =
    let
        selected =
            List.member slot item.photos

        maybeRecord =
            savedListRecord model

        isSaved =
            maybeRecord
                |> Maybe.map (\record -> Dict.member slot record.savedPhotos)
                |> Maybe.withDefault False

        maybeImageUrl =
            maybeRecord |> Maybe.andThen (\record -> savedPhotoUrlForModel model record slot)

        inputId =
            "item-photo-" ++ String.fromInt index ++ "-" ++ slot

        labelText =
            "Galleriakuva " ++ String.fromInt (position + 1)
    in
    label [ for inputId, class "inline-flex min-h-11 items-center gap-2 type-body-small" ]
        [ input
            [ id inputId
            , type_ "checkbox"
            , checked selected
            , disabled (not isSaved && not selected)
            , onCheck (ItemPhotoToggled index slot)
            ]
            []
        , case maybeImageUrl of
            Just imageUrl ->
                img
                    [ src imageUrl
                    , alt ""
                    , attribute "loading" "lazy"
                    , attribute "referrerpolicy" "no-referrer"
                    , class "h-10 w-10 rounded object-contain"
                    ]
                    []

            Nothing ->
                text ""
        , text
            (if isSaved then
                labelText

             else
                labelText ++ " (tyhjä)"
            )
        ]


viewCatalogSnapshot : Maybe Types.SetCatalog -> Html Msg
viewCatalogSnapshot maybeCatalog =
    case maybeCatalog of
        Just catalog ->
            div [ class "mt-2 flex flex-wrap items-center gap-3 type-caption text-text-muted" ]
                ((case catalog.imageUrl of
                    Just imageUrl ->
                        [ img [ src imageUrl, alt (catalog.name ++ " - " ++ catalogProviderName catalog.provider), attribute "loading" "lazy", attribute "referrerpolicy" "no-referrer", class "h-16 w-16 rounded object-contain" ] [] ]

                    Nothing ->
                        []
                 )
                    ++ [ span [] [ text (catalogSummary catalog) ] ]
                )

        Nothing ->
            text ""


viewItemThumbnails : String -> Dict String Types.SetCatalog -> Dict String String -> SetItem -> Html Msg
viewItemThumbnails layoutClass catalogsByCode galleryUrls item =
    let
        setImages =
            item.codes
                |> List.filterMap (\code -> Dict.get code catalogsByCode)
                |> List.filterMap (\catalog -> Maybe.map (\imageUrl -> ( imageUrl, "Setin kuva: " ++ catalog.name )) catalog.imageUrl)

        itemLabel =
            if String.trim item.title == "" then
                "Kohteen kuva"

            else
                "Kohteen kuva: " ++ item.title

        galleryImages =
            item.photos
                |> List.filterMap (\slot -> Dict.get slot galleryUrls)
                |> List.map (\imageUrl -> ( imageUrl, itemLabel ))

        images =
            setImages ++ galleryImages
    in
    if List.isEmpty images then
        text ""

    else
        div [ class layoutClass ] (List.map (\( imageUrl, altText ) -> viewThumbnailImage imageUrl altText) images)


viewThumbnailImage : String -> String -> Html Msg
viewThumbnailImage imageUrl altText =
    img
        [ src imageUrl
        , alt altText
        , attribute "loading" "lazy"
        , attribute "referrerpolicy" "no-referrer"
        , class "h-32 w-32 max-w-full rounded object-contain object-top pt-2"
        ]
        []


catalogSummary : Types.SetCatalog -> String
catalogSummary catalog =
    catalogProviderName catalog.provider
        ++ " · "
        ++ catalog.name
        ++ (catalog.year |> Maybe.map (\year -> " · " ++ String.fromInt year) |> Maybe.withDefault "")
        ++ (catalog.pieces |> Maybe.map (\pieces -> " · " ++ String.fromInt pieces ++ " osaa") |> Maybe.withDefault "")


catalogProviderName : Types.CatalogProvider -> String
catalogProviderName provider =
    case provider of
        Types.RebrickableCatalog ->
            "Rebrickable"

        Types.BricksetCatalog ->
            "Brickset"


viewCodeLinks : List Service -> Dict String Types.SetCatalog -> String -> Html Msg
viewCodeLinks services catalogsByCode code =
    div [ class "flex flex-wrap items-center gap-x-4 gap-y-2" ]
        [ span [ class "inline-flex items-center gap-2 type-mono" ]
            ([ FeatherIcons.package
                |> FeatherIcons.withSize 14
                |> FeatherIcons.toHtml [ attribute "aria-hidden" "true", attribute "focusable" "false", SvgA.class "text-text-muted" ]
             , text code
             ]
                ++ (case catalogYearForCode catalogsByCode code of
                        Just year ->
                            [ span [ class "inline-flex items-center gap-1 type-body-small text-text-muted" ]
                                [ FeatherIcons.calendar
                                    |> FeatherIcons.withSize 14
                                    |> FeatherIcons.toHtml [ attribute "aria-hidden" "true", attribute "focusable" "false" ]
                                , text (String.fromInt year)
                                ]
                            ]

                        Nothing ->
                            []
                   )
            )
        , if List.isEmpty services then
            span [ class "type-caption text-text-muted self-center" ] [ text "Ei valittuja palveluita" ]

          else
            div [ class "relative -top-px flex flex-wrap items-center gap-x-4 gap-y-2 self-center" ]
                (List.map
                    (\service -> a [ href (Api.serviceHref service code), target "_blank", attribute "rel" "noopener noreferrer", class "no-print type-body-small text-brand underline" ] [ text (Types.serviceName service) ])
                    services
                )
        ]


catalogYearForCode : Dict String Types.SetCatalog -> String -> Maybe Int
catalogYearForCode catalogsByCode code =
    Dict.get code catalogsByCode |> Maybe.andThen .year


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
        section [ class "markdown-content mt-4 max-w-none type-body" ] (markdownNodes markdown)


viewItemMarkdown : String -> Html Msg
viewItemMarkdown markdown =
    if String.trim markdown == "" then
        text ""

    else
        div [ class "markdown-content mt-2 max-w-none type-body" ] (markdownNodes markdown)


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
            "https://esite.palikkaharrastajat.fi/#/" ++ id
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
                            "Uusi pöytäesite"

                         else
                            "Muokkaa pöytäesitettä"
                        )
                    ]
                , p [ class "mt-2 type-body text-text-muted" ] [ text "Järjestä teokset ja täydennä listan kuvaus." ]
                ]
            , Button.link { label = "Peruuta", href = "#/" }
                |> Button.withVariant Button.Secondary
                |> Button.withSize Button.Small
                |> Button.toHtml
            ]
        , div [ class "space-y-6 rounded-lg bg-white" ]
            [ Form.textInput (Form.defaultField "title" "Listan otsikko")
                { value = model.form.title
                , onInput = TitleChanged
                , inputType = Form.Text
                , placeholder = Just "Esim. Keskiaikaiset linnat"
                }
            , editorTabs model.editorTab
            , div
                [ attribute "role" "tabpanel"
                , attribute "tabindex" "0"
                , id (editorPanelId model.editorTab)
                , attribute "aria-labelledby" (editorTabId model.editorTab)
                ]
                [ case model.editorTab of
                    ItemsTab ->
                        viewEditSets model

                    DescriptionTab ->
                        div [ class "space-y-4" ]
                            [ Form.textInput (Form.defaultField "description" "Alaotsikko")
                                { value = model.form.description
                                , onInput = DescriptionChanged
                                , inputType = Form.Text
                                , placeholder = Nothing
                                }
                            , markdownEditor (List.member "list-markdown" model.markdownPreviewIds) "list-markdown" "Kuvaus" model.form.markdown MarkdownChanged
                            , viewPhotoSlotEditor model maybeId Types.coverPhotoSlot "Listan kansikuva"
                            , photoHelp maybeId
                            ]

                    PhotosTab ->
                        div [ class "space-y-6" ]
                            (photoHelp maybeId
                                :: List.indexedMap
                                    (\index slot -> viewPhotoSlotEditor model maybeId slot ("Galleriakuva " ++ String.fromInt (index + 1)))
                                    Types.galleryPhotoSlots
                            )
                ]
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
            , div [ class "flex flex-wrap items-center gap-3 border-t border-border-default pt-5" ]
                [ sharedButton "Tallenna lista" SaveClicked Button.Primary (model.saving || photoActionInProgress model.photoUploadState) model.saving
                , case maybeId of
                    Just _ ->
                        deleteListButton (model.saving || photoActionInProgress model.photoUploadState)

                    Nothing ->
                        text ""
                ]
            ]
        ]


{-| Short-lived file tokens expire while an editor stays open, so switching tabs asks for a fresh one.
-}
refreshPhotoFileToken : Model -> Cmd Msg
refreshPhotoFileToken model =
    case ( model.route, model.currentList, getToken model.auth ) of
        ( Route.EditList (Just routeId), Loaded record, Just token ) ->
            if routeId == record.id && not (Dict.isEmpty record.savedPhotos) then
                requestListPhotoFileToken { listId = record.id, pbBaseUrl = model.pbBaseUrl, token = token }

            else
                Cmd.none

        _ ->
            Cmd.none


savedListRecord : Model -> Maybe ListRecord
savedListRecord model =
    case ( model.route, model.currentList ) of
        ( Route.EditList (Just routeId), Loaded record ) ->
            if routeId == record.id then
                Just record

            else
                Nothing

        _ ->
            Nothing


photoInputId : String -> String
photoInputId slot =
    "list-photo-input-" ++ slot


photoHelp : Maybe String -> Html Msg
photoHelp maybeId =
    p [ id "list-photo-help", class "type-caption text-text-muted" ]
        [ text
            (if maybeId == Nothing then
                "Tallenna lista ensin, avaa se muokattavaksi ja lisää sitten kuva."

             else
                "Ota kuva tai valitse kuvatiedosto, rajaa se kuvasuhteen ja zoomauksen avulla. Rajattu kuva pienennetään enintään 256 pikseliin ja tallennetaan WebP-kuvana (enintään 200 kt). Enimmäiskoko ennen käsittelyä on 20 Mt."
            )
        ]


photoStatus : Bool -> String -> Html Msg
photoStatus isAlert message =
    if isAlert then
        p [ id "list-photo-status", attribute "role" "alert", class "type-caption text-brand-red" ] [ text message ]

    else
        p [ id "list-photo-status", attribute "role" "status", attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text message ]


viewPhotoSlotEditor : Model -> Maybe String -> String -> String -> Html Msg
viewPhotoSlotEditor model maybeId slot labelText =
    let
        maybeRecord =
            savedListRecord model

        maybePhotoUrl =
            maybeRecord |> Maybe.andThen (\record -> savedPhotoUrlForModel model record slot)

        hasPhoto =
            maybeRecord
                |> Maybe.map (\record -> Dict.member slot record.savedPhotos)
                |> Maybe.withDefault False

        isActive =
            model.photoSlot == slot

        photoInputAttributes =
            case maybeId of
                Just listId ->
                    [ on "change"
                        (Decode.at [ "target", "files" ] (Decode.index 0 File.decoder)
                            |> Decode.map (\_ -> ListPhotoSelected slot listId)
                        )
                    ]

                Nothing ->
                    []

        statusView =
            if not isActive then
                text ""

            else
                case model.photoUploadState of
                    PhotoReady ->
                        text ""

                    PhotoPreparing ->
                        photoStatus False "Kuvaa valmistellaan…"

                    PhotoCropping ->
                        photoStatus False "Rajaa kuva alla olevilla valinnoilla ja tallenna se."

                    PhotoUploading ->
                        photoStatus False "Kuvaa käsitellään ja tallennetaan…"

                    PhotoRemoving ->
                        photoStatus False "Kuvaa poistetaan…"

                    PhotoUploaded ->
                        photoStatus False "Kuva tallennettiin."

                    PhotoRemoved ->
                        photoStatus False "Kuva poistettiin."

                    PhotoUploadFailed message ->
                        photoStatus True message
    in
    div [ class "space-y-3" ]
        [ label [ class "block type-body-small mb-1 text-text-primary", attribute "for" (photoInputId slot) ] [ text labelText ]
        , input
            ([ id (photoInputId slot)
             , type_ "file"
             , attribute "accept" "image/*"
             , attribute "aria-describedby" "list-photo-help"
             , disabled (maybeId == Nothing || photoActionInProgress model.photoUploadState)
             , class inputClass
             ]
                ++ photoInputAttributes
            )
            []
        , statusView
        , case ( model.photoUploadState, model.photoCrop ) of
            ( PhotoCropping, Just crop ) ->
                if isActive then
                    photoCropPanel labelText crop

                else
                    text ""

            _ ->
                text ""
        , if hasPhoto then
            div [ class "flex flex-wrap items-start gap-3" ]
                [ case maybePhotoUrl of
                    Just imageUrl ->
                        img
                            [ src imageUrl
                            , alt ("Nykyinen kuva: " ++ labelText)
                            , attribute "loading" "eager"
                            , attribute "referrerpolicy" "no-referrer"
                            , class "h-32 w-32 rounded object-contain object-top pt-2"
                            ]
                            []

                    Nothing ->
                        text ""
                , button
                    [ type_ "button"
                    , onClick (ListPhotoClearClicked slot)
                    , disabled (photoActionInProgress model.photoUploadState)
                    , attribute "aria-label" ("Poista kuva: " ++ labelText)
                    , class "inline-flex min-h-11 items-center justify-center rounded border border-red-300 px-4 py-2 type-body-small font-semibold text-red-700 hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500 disabled:cursor-not-allowed disabled:opacity-50"
                    ]
                    [ text "Poista kuva" ]
                ]

          else
            text ""
        ]


photoCropPanel : String -> PhotoCrop.State -> Html Msg
photoCropPanel labelText crop =
    let
        region =
            PhotoCrop.cropRegion crop

        output =
            PhotoCrop.outputSize region

        sourceWidth =
            toFloat crop.sourceWidth

        sourceHeight =
            toFloat crop.sourceHeight

        selectionStyles =
            [ style "left" (percentOf (toFloat region.x / sourceWidth * 100))
            , style "top" (percentOf (toFloat region.y / sourceHeight * 100))
            , style "width" (percentOf (toFloat region.width / sourceWidth * 100))
            , style "height" (percentOf (toFloat region.height / sourceHeight * 100))
            ]

        ratioOption ratio =
            label
                [ class "flex min-h-11 cursor-pointer items-center gap-2 rounded border border-border-default bg-white px-3 py-2 type-body-small has-[:checked]:border-brand has-[:checked]:bg-bg-subtle has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-brand" ]
                [ input
                    [ type_ "radio"
                    , attribute "name" "list-photo-crop-ratio"
                    , value (PhotoCrop.ratioId ratio)
                    , checked (crop.ratio == ratio)
                    , onCheck (\_ -> PhotoCropRatioSelected ratio)
                    , class "h-5 w-5 shrink-0"
                    ]
                    []
                , text (PhotoCrop.ratioLabel ratio)
                ]
    in
    section [ id "list-photo-crop", class "space-y-4 rounded-lg border border-border-default bg-white p-4", attribute "aria-labelledby" "list-photo-crop-title" ]
        [ h3 [ id "list-photo-crop-title", class "type-h4" ] [ text ("Rajaa kuva: " ++ labelText) ]
        , div
            [ class "relative mx-auto w-full max-w-sm touch-none select-none overflow-hidden rounded bg-bg-subtle cursor-grab active:cursor-grabbing focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand"
            , style "aspect-ratio" (String.fromInt crop.sourceWidth ++ " / " ++ String.fromInt crop.sourceHeight)
            , attribute "data-crop-frame" ""
            , attribute "role" "group"
            , attribute "tabindex" "0"
            , attribute "aria-label" ("Rajausalue: " ++ labelText)
            , attribute "aria-describedby" "list-photo-crop-hint"
            , preventDefaultOn "keydown" cropFrameKeyDecoder
            ]
            [ img
                [ src crop.previewUrl
                , alt ("Esikatselu rajausalueineen: " ++ labelText)
                , attribute "draggable" "false"
                , class "block h-full w-full select-none"
                ]
                []
            , div
                ([ attribute "aria-hidden" "true"
                 , class "pointer-events-none absolute border-2 border-white"
                 , style "box-shadow" "0 0 0 9999px rgba(0, 0, 0, 0.5)"
                 ]
                    ++ selectionStyles
                )
                []
            ]
        , p [ id "list-photo-crop-hint", class "type-caption text-text-muted" ]
            [ text "Vedä rajaus siirtääksesi sitä. Nipistä ulospäin loitontaaksesi ja sisäänpäin lähentääksesi. Zoomaa myös hiiren rullalla. Kehyksen ollessa valittuna nuolinäppäimet siirtävät ja + ja - zoomaavat."
            ]
        , fieldset [ class "space-y-2" ]
            [ legend [ class "type-body-small font-semibold" ] [ text "Kuvasuhde" ]
            , div [ class "grid grid-cols-1 gap-2 sm:grid-cols-2" ] (List.map ratioOption PhotoCrop.allRatios)
            , p [ id "list-photo-crop-size", attribute "aria-live" "polite", class "type-caption text-text-muted" ]
                [ text ("Tallennettava koko: " ++ String.fromInt output.width ++ " × " ++ String.fromInt output.height ++ " px, WebP, enintään 200 kt.") ]
            ]
        , cropSlider
            { fieldId = "list-photo-crop-zoom"
            , labelText = "Zoomaus"
            , valueText = String.fromInt (round (crop.zoom * 100)) ++ " %"
            , minValue = PhotoCrop.minZoom
            , maxValue = PhotoCrop.maxZoom
            , step = 0.01
            , current = crop.zoom
            , toMsg = PhotoCropZoomChanged
            }
        , cropSlider
            { fieldId = "list-photo-crop-focus-x"
            , labelText = "Vaakasuuntainen sijainti"
            , valueText = String.fromInt (round (crop.focusX * 100)) ++ " %"
            , minValue = 0
            , maxValue = 1
            , step = 0.01
            , current = crop.focusX
            , toMsg = PhotoCropFocusXChanged
            }
        , cropSlider
            { fieldId = "list-photo-crop-focus-y"
            , labelText = "Pystysuuntainen sijainti"
            , valueText = String.fromInt (round (crop.focusY * 100)) ++ " %"
            , minValue = 0
            , maxValue = 1
            , step = 0.01
            , current = crop.focusY
            , toMsg = PhotoCropFocusYChanged
            }
        , div [ class "flex flex-wrap items-center gap-3" ]
            [ button
                [ type_ "button"
                , onClick PhotoCropCancelClicked
                , class "inline-flex min-h-11 items-center justify-center rounded border border-brand bg-white px-4 py-2 type-body-small font-semibold text-brand hover:bg-bg-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
                ]
                [ text "Peruuta" ]
            , sharedButton "Tallenna kuva" PhotoCropApplyClicked Button.Primary False False
            ]
        ]


cropSlider :
    { fieldId : String
    , labelText : String
    , valueText : String
    , minValue : Float
    , maxValue : Float
    , step : Float
    , current : Float
    , toMsg : String -> Msg
    }
    -> Html Msg
cropSlider config =
    div [ class "space-y-1" ]
        [ label [ for config.fieldId, class "block type-body-small" ]
            [ text (config.labelText ++ ": " ++ config.valueText) ]
        , input
            [ type_ "range"
            , id config.fieldId
            , attribute "min" (String.fromFloat config.minValue)
            , attribute "max" (String.fromFloat config.maxValue)
            , attribute "step" (String.fromFloat config.step)
            , value (String.fromFloat config.current)
            , onInput config.toMsg
            , class "block min-h-11 w-full"
            ]
            []
        ]


percentOf : Float -> String
percentOf value =
    String.fromFloat value ++ "%"


updatePhotoCrop : Model -> (PhotoCrop.State -> PhotoCrop.State) -> ( Model, Cmd Msg )
updatePhotoCrop model change =
    case ( model.photoUploadState, model.photoCrop ) of
        ( PhotoCropping, Just crop ) ->
            ( { model | photoCrop = Just (change crop) }, Cmd.none )

        _ ->
            ( model, Cmd.none )


type PhotoCropKey
    = CropPan Float Float
    | CropZoom Float


photoCropKey : String -> Maybe PhotoCropKey
photoCropKey key =
    case key of
        "ArrowLeft" ->
            Just (CropPan -0.1 0)

        "ArrowRight" ->
            Just (CropPan 0.1 0)

        "ArrowUp" ->
            Just (CropPan 0 -0.1)

        "ArrowDown" ->
            Just (CropPan 0 0.1)

        "+" ->
            Just (CropZoom 1.1)

        "=" ->
            Just (CropZoom 1.1)

        "-" ->
            Just (CropZoom (1 / 1.1))

        _ ->
            Nothing


cropFrameKeyDecoder : Decode.Decoder ( Msg, Bool )
cropFrameKeyDecoder =
    Decode.field "key" Decode.string
        |> Decode.map (\key -> ( PhotoCropKeyPressed key, photoCropKey key /= Nothing ))


photoActionInProgress : PhotoUploadState -> Bool
photoActionInProgress state =
    case state of
        PhotoPreparing ->
            True

        PhotoCropping ->
            True

        PhotoUploading ->
            True

        PhotoRemoving ->
            True

        _ ->
            False


photoUploadErrorMessage : String -> String
photoUploadErrorMessage code =
    case code of
        "photo-too-large" ->
            "Kuvan alkuperäinen tiedosto saa olla enintään 20 Mt."

        "unsupported-image" ->
            "Valitse kuvatiedosto, jonka selain pystyy avaamaan."

        _ ->
            "Kuvaa ei voitu käsitellä tai tallentaa. Valitse toinen kuva ja yritä uudelleen."


editorTabs : EditorTab -> Html Msg
editorTabs activeTab =
    let
        tabButton : EditorTab -> String -> Html Msg
        tabButton tab labelText =
            let
                isSelected =
                    activeTab == tab
            in
            button
                [ type_ "button"
                , class
                    ("border-b-2 px-4 py-3 type-body-small focus-visible:ring-2 focus-visible:ring-brand "
                        ++ (if isSelected then
                                "border-brand text-brand"

                            else
                                "border-transparent text-text-muted hover:text-brand"
                           )
                    )
                , onClick (SelectEditorTab tab)
                , attribute "tabindex"
                    (if isSelected then
                        "0"

                     else
                        "-1"
                    )
                , preventDefaultOn "keydown"
                    (Decode.map
                        (\key ->
                            if List.member key [ "ArrowLeft", "ArrowRight", "Home", "End" ] then
                                ( EditorTabKeyPressed key, True )

                            else
                                ( NoOp, False )
                        )
                        (Decode.field "key" Decode.string)
                    )
                , attribute "role" "tab"
                , attribute "aria-selected"
                    (if isSelected then
                        "true"

                     else
                        "false"
                    )
                , attribute "aria-controls" (editorPanelId tab)
                , attribute "title" labelText
                , id (editorTabId tab)
                ]
                [ text labelText ]
    in
    div [ class "flex items-center" ]
        [ div
            [ class "flex border-b border-border-default"
            , attribute "role" "tablist"
            , attribute "aria-label" "Listan muokkausosiot"
            , attribute "aria-orientation" "horizontal"
            ]
            [ tabButton ItemsTab "Teokset"
            , tabButton DescriptionTab "Kuvaus"
            , tabButton PhotosTab "Kuvat"
            ]
        , if activeTab == ItemsTab then
            div [ class "ml-auto" ]
                [ sharedButton "Lisää kohde" AddSet Button.Secondary False False ]

          else
            text ""
        ]


viewEditSets : Model -> Html Msg
viewEditSets model =
    section []
        [ if List.isEmpty model.form.items then
            p [ class "rounded border border-border-default p-4 type-caption text-text-muted" ] [ text "Listalla ei ole vielä kohteita." ]

          else
            div [ class "space-y-3" ] (List.indexedMap (viewEditSetRow model model.markdownPreviewIds model.form.items) model.form.items)
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
    button
        ([ type_ "button"
         , class "inline-flex h-[45px] w-[45px] shrink-0 items-center justify-center rounded border border-brand bg-white text-brand hover:bg-bg-subtle focus-visible:ring-2 focus-visible:ring-brand disabled:cursor-not-allowed disabled:opacity-50"
         , disabled isDisabled
         , attribute "aria-label" labelText
         , attribute "title" labelText
         ]
            ++ (if isDisabled then
                    []

                else
                    [ onClick message ]
               )
        )
        [ icon
            |> FeatherIcons.withSize 16
            |> FeatherIcons.toHtml [ attribute "aria-hidden" "true", attribute "focusable" "false" ]
        ]


viewDeleteConfirmation : Bool -> Html Msg
viewDeleteConfirmation isOpen =
    if not isOpen then
        text ""

    else
        div
            [ class "no-print fixed inset-0 z-50 flex items-center justify-center p-4"
            , attribute "role" "alertdialog"
            , attribute "aria-modal" "true"
            , attribute "aria-labelledby" "delete-dialog-title"
            , attribute "aria-describedby" "delete-dialog-description"
            , deleteDialogKeyHandler
            ]
            [ div
                [ class "absolute inset-0 bg-black/50"
                , attribute "aria-hidden" "true"
                , onClick CancelDelete
                ]
                []
            , section [ class "relative z-10 w-full max-w-lg rounded-xl bg-white p-6 shadow-xl" ]
                [ header [ class "mb-4 flex items-center justify-between gap-4" ]
                    [ h2 [ id "delete-dialog-title", class "type-h3" ] [ text "Poistetaanko lista?" ]
                    , button
                        [ type_ "button"
                        , id "delete-dialog-close"
                        , class "inline-flex h-11 w-11 items-center justify-center rounded text-text-muted hover:bg-bg-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
                        , attribute "aria-label" "Sulje"
                        , onClick CancelDelete
                        ]
                        [ FeatherIcons.x |> FeatherIcons.withSize 18 |> FeatherIcons.toHtml [ attribute "aria-hidden" "true", attribute "focusable" "false" ] ]
                    ]
                , p [ id "delete-dialog-description", class "type-body" ] [ text "Listan poistamista ei voi perua." ]
                , div [ class "mt-6 flex flex-wrap justify-end gap-3" ]
                    [ button
                        [ type_ "button"
                        , id "delete-dialog-cancel"
                        , class "inline-flex min-h-11 items-center justify-center rounded border border-border-default bg-white px-4 py-2 type-body-small font-semibold text-brand hover:bg-bg-subtle focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand"
                        , onClick CancelDelete
                        ]
                        [ text "Peruuta" ]
                    , button
                        [ type_ "button"
                        , id "delete-dialog-confirm"
                        , class "inline-flex min-h-11 items-center justify-center rounded bg-red-600 px-4 py-2 type-body-small font-semibold text-white hover:bg-red-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500"
                        , onClick ConfirmDelete
                        ]
                        [ text "Poista lista" ]
                    ]
                ]
            ]


deleteDialogKeyHandler : Html.Attribute Msg
deleteDialogKeyHandler =
    preventDefaultOn "keydown"
        (Decode.map3
            (\key shiftKey targetId ->
                if key == "Escape" then
                    ( CancelDelete, True )

                else if key == "Tab" && shiftKey && targetId == "delete-dialog-close" then
                    ( FocusDeleteDialog "delete-dialog-confirm", True )

                else if key == "Tab" && not shiftKey && targetId == "delete-dialog-confirm" then
                    ( FocusDeleteDialog "delete-dialog-close", True )

                else
                    ( NoOp, False )
            )
            (Decode.field "key" Decode.string)
            (Decode.field "shiftKey" Decode.bool)
            (Decode.at [ "target", "id" ] Decode.string)
        )


deleteListButton : Bool -> Html Msg
deleteListButton isDisabled =
    button
        [ type_ "button"
        , id "delete-list-button"
        , disabled isDisabled
        , class "ml-auto inline-flex min-h-11 items-center justify-center rounded bg-red-600 px-4 py-2 type-body-small font-semibold text-white hover:bg-red-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500 disabled:cursor-not-allowed disabled:opacity-50"
        , onClick DeleteClicked
        ]
        [ text "Poista lista" ]


deleteSetButton : Int -> String -> Html Msg
deleteSetButton index itemTitle =
    button
        [ type_ "button"
        , class "inline-flex min-h-11 items-center justify-center rounded bg-red-600 px-4 py-2 type-body-small font-semibold text-white transition-all hover:bg-red-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500"
        , attribute "aria-label" ("Poista kohde: " ++ itemTitle)
        , onClick (RemoveSet index)
        ]
        [ text "Poista" ]


fieldLabel : String -> String -> Html Msg -> Html Msg
fieldLabel labelText id control =
    label [ class "block type-body-small" ]
        [ span [ class "mb-2 block" ] [ text labelText ]
        , div [ attribute "id" ("field-" ++ id) ] [ control ]
        ]


viewEditSet : Model -> List String -> List SetItem -> Int -> SetItem -> Html Msg
viewEditSet model previewIds items index item =
    let
        isOpen =
            model.openSetIndex == Just index

        itemTitle =
            if String.trim item.title == "" then
                "Kohde " ++ String.fromInt (index + 1)

            else
                item.title

        detailsId =
            "edit-set-" ++ String.fromInt index
    in
    section
        [ class
            (if model.draggingSetIndex == Just index then
                "overflow-hidden rounded-lg border border-border-default bg-white opacity-60"

             else
                "overflow-hidden rounded-lg border border-border-default bg-white"
            )
        ]
        [ div [ class "flex flex-wrap items-center gap-2 p-3" ]
            [ span
                [ class "grid h-11 w-8 cursor-grab touch-none place-items-center rounded text-text-muted hover:bg-bg-subtle active:cursor-grabbing"
                , attribute "draggable" "true"
                , attribute "data-set-drag-handle" ""
                , attribute "data-set-index" (String.fromInt index)
                , attribute "title" ("Vedä järjestääksesi: " ++ itemTitle)
                , attribute "aria-hidden" "true"
                , on "dragstart" (Decode.succeed (SetDragStarted index))
                , on "dragend" (Decode.succeed SetDragEnded)
                ]
                [ span [ class "grid grid-cols-2 gap-1" ] (List.repeat 6 (span [ class "h-1 w-1 rounded-full bg-current" ] [])) ]
            , iconButton ("Siirrä ylemmäs: " ++ itemTitle) FeatherIcons.arrowUp (MoveSet index (index - 1)) (index == 0)
            , iconButton ("Siirrä alemmas: " ++ itemTitle) FeatherIcons.arrowDown (MoveSet index (index + 1)) (index == List.length items - 1)
            , button
                [ type_ "button"
                , id ("edit-set-toggle-" ++ String.fromInt index)
                , class "flex min-w-0 flex-1 items-center justify-start gap-3 rounded p-2 text-left hover:bg-bg-subtle focus-visible:outline focus-visible:outline-2 focus-visible:outline-brand"
                , onClick (ToggleSetAccordion index)
                , attribute "aria-expanded"
                    (if isOpen then
                        "true"

                     else
                        "false"
                    )
                , attribute "aria-controls" detailsId
                , attribute "aria-label"
                    ((if isOpen then
                        "Sulje kohde: "

                      else
                        "Avaa kohde: "
                     )
                        ++ itemTitle
                    )
                , attribute "title"
                    ((if isOpen then
                        "Sulje kohde: "

                      else
                        "Avaa kohde: "
                     )
                        ++ itemTitle
                    )
                ]
                [ span [ class "min-w-0 truncate type-h4" ] [ text itemTitle ]
                , span [ class "shrink-0 text-text-muted", attribute "aria-hidden" "true" ]
                    [ (if isOpen then
                        FeatherIcons.chevronUp

                       else
                        FeatherIcons.chevronDown
                      )
                        |> FeatherIcons.withSize 18
                        |> FeatherIcons.toHtml [ attribute "focusable" "false" ]
                    ]
                ]
            , deleteSetButton index itemTitle
            ]
        , if isOpen then
            div [ id detailsId, class "space-y-4 border-t border-border-default p-4" ]
                [ viewSetSearch model index item
                , Form.radioGroup
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
                , Form.textInput (Form.defaultField ("item-title-" ++ String.fromInt index) "Kohteen otsikko")
                    { value = item.title, onInput = ItemTitleChanged index, inputType = Form.Text, placeholder = Just "Esim. Millennium Falcon" }
                , if Types.itemHasTitle item then
                    text ""

                  else
                    p [ class "mt-1 type-caption text-red-700" ] [ text "Otsikko vaaditaan jokaiselle kohteelle." ]
                , markdownEditor
                    (List.member ("item-description-" ++ String.fromInt index) previewIds)
                    ("item-description-" ++ String.fromInt index)
                    "Kohteen kuvaus"
                    item.description
                    (ItemDescriptionChanged index)
                , Form.textInput (Form.defaultField ("url-" ++ String.fromInt index) "Lisätietojen URL")
                    { value = item.url, onInput = ItemUrlChanged index, inputType = Form.Url, placeholder = Just "https://example.com" }
                , viewCatalogSnapshot item.catalog
                , viewItemPhotoChoices model index item
                , fieldset [ class "mt-4" ]
                    [ Html.legend [ class "type-caption text-text-muted" ] [ text "Näytä linkit palveluissa" ]
                    , div [ class "mt-2 flex flex-wrap gap-x-5 gap-y-2" ]
                        (List.map (serviceCheckbox index item.services) [ Lego, Brickset, Bricklink, Rebrickable ])
                    ]
                ]

          else
            text ""
        ]


viewEditSetRow : Model -> List String -> List SetItem -> Int -> SetItem -> Html Msg
viewEditSetRow model previewIds items index item =
    div [ class "relative" ]
        (viewEditSet model previewIds items index item :: viewDropZones model index (List.length items))


{-| While a row is dragged, the top and bottom halves of every row accept a drop into the gap they
border. The gap that would change the order shows a line on its edge.
-}
viewDropZones : Model -> Int -> Int -> List (Html Msg)
viewDropZones model index count =
    case model.draggingSetIndex of
        Nothing ->
            []

        Just fromIndex ->
            let
                dropZone : Bool -> Int -> Html Msg
                dropZone isTop gap =
                    let
                        showLine =
                            model.dropGap
                                == Just gap
                                && ItemOrder.targetIndex fromIndex gap
                                /= fromIndex
                                && (isTop || gap == count)

                        edgeClass =
                            if isTop then
                                "top-0"

                            else
                                "bottom-0"
                    in
                    div
                        [ class ("absolute inset-x-0 z-10 h-1/2 " ++ edgeClass)
                        , preventDefaultOn "dragover" (Decode.succeed ( SetDropGapChanged gap, True ))
                        , preventDefaultOn "drop" (Decode.succeed ( SetDragDropped gap, True ))
                        ]
                        (if showLine then
                            [ div [ class ("absolute inset-x-0 z-20 h-1 rounded bg-brand " ++ edgeClass), attribute "aria-hidden" "true" ] [] ]

                         else
                            []
                        )
            in
            [ dropZone True index
            , dropZone False (index + 1)
            ]


viewSetSearch : Model -> Int -> SetItem -> Html Msg
viewSetSearch model index item =
    let
        inputId =
            "item-search-" ++ String.fromInt index

        listId =
            inputId ++ "-suggestions"

        query =
            Dict.get index model.setSearchQueries |> Maybe.withDefault ""

        itemLabel =
            if String.trim item.title == "" then
                itemKindName item.kind

            else
                item.title

        searchState =
            Dict.get index model.setSearchStates

        suggestions =
            case searchState of
                Just (SetSearchResults _ _ results) ->
                    results

                _ ->
                    []

        expanded =
            not (List.isEmpty suggestions)

        activeSuggestionIndex =
            Dict.get index model.activeSuggestions |> Maybe.withDefault 0

        keyboardAttributes =
            if expanded then
                [ preventDefaultOn "keydown"
                    (Decode.map2
                        (\key ctrlKey ->
                            if List.member key [ "ArrowDown", "ArrowUp", "Enter", "Escape" ] && not (ctrlKey && key == "Enter") then
                                ( SetSearchKeyPressed index key, True )

                            else
                                ( NoOp, False )
                        )
                        (Decode.field "key" Decode.string)
                        (Decode.field "ctrlKey" Decode.bool)
                    )
                ]

            else
                []

        status =
            case searchState of
                Just (SetSearchWaiting _ _) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text "Etsitään Rebrickablesta…" ]

                Just (SetSearchLoading _ _) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text "Etsitään Rebrickablesta…" ]

                Just (SetSearchResults _ _ results) ->
                    if List.isEmpty results then
                        p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text "Settiä ei löytynyt. Kokeile toista hakusanaa tai setin tunnusta." ]

                    else
                        text ""

                Just (SetSearchFailed _ _ message) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-brand-red" ] [ text message ]

                Just (SetSearchEnriching _ _ _) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text "Tietoja ja pikkukuvaa haetaan Bricksetistä…" ]

                Just (SetSearchSavingThumbnail _ _ _) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text "Muunnetaan pikkukuvaa 256px WebP-muotoon ja tallennetaan…" ]

                Just (SetSearchEnriched _ _ hasBricksetMetadata hasThumbnail) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ]
                        [ text
                            (case ( hasBricksetMetadata, hasThumbnail ) of
                                ( True, True ) ->
                                    "Setti lisättiin. Brickset-tiedot ja WebP-pikkukuva tallennettiin."

                                ( True, False ) ->
                                    "Setti lisättiin. Brickset-tiedot tallennettiin, mutta pikkukuvaa ei saatu."

                                ( False, True ) ->
                                    "Setti lisättiin. Rebrickable-pikkukuva tallennettiin WebP-muodossa; Brickset-tietoja ei saatu."

                                ( False, False ) ->
                                    "Setti lisättiin. Brickset-tietoja ja pikkukuvaa ei saatu."
                            )
                        ]

                Just (SetSearchEnrichmentFailed _ _) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text "Setti lisättiin, mutta Brickset-tietoja ei saatu. Otsikko ja tunnus ovat täytettyinä." ]

                Just (SetSearchCodeAdded message) ->
                    p [ attribute "aria-live" "polite", class "type-caption text-text-muted" ] [ text message ]

                Nothing ->
                    text ""

        suggestionOption requestId suggestionIndex suggestion =
            let
                metadata =
                    [ Just suggestion.code
                    , Maybe.map String.fromInt suggestion.year
                    , Maybe.map (\pieces -> String.fromInt pieces ++ " osaa") suggestion.pieces
                    ]
                        |> List.filterMap identity
                        |> String.join " · "
            in
            li
                [ id (inputId ++ "-option-" ++ String.fromInt suggestionIndex)
                , class
                    ("cursor-pointer px-3 py-2 "
                        ++ (if suggestionIndex == activeSuggestionIndex then
                                "bg-bg-subtle"

                            else
                                "hover:bg-bg-subtle"
                           )
                    )
                , onClick (SetSuggestionSelected index requestId suggestion)
                , attribute "role" "option"
                , attribute "aria-selected"
                    (if suggestionIndex == activeSuggestionIndex then
                        "true"

                     else
                        "false"
                    )
                ]
                [ span [ class "block type-body-small" ] [ text suggestion.name ]
                , span [ class "block type-caption text-text-muted" ] [ text metadata ]
                ]

        suggestionsView =
            case searchState of
                Just (SetSearchResults requestId _ results) ->
                    if List.isEmpty results then
                        text ""

                    else
                        ul
                            [ id listId
                            , class "max-h-72 overflow-y-auto rounded border border-border-default bg-white"
                            , attribute "role" "listbox"
                            , attribute "aria-label" "Rebrickable-settiehdotukset"
                            ]
                            (List.indexedMap (suggestionOption requestId) results)

                _ ->
                    text ""

        codesWidget =
            fieldset [ class "space-y-2" ]
                [ Html.legend [ class "type-body-small" ] [ text "Settinumerot" ]
                , if List.isEmpty item.codes then
                    text ""

                  else
                    ul [ class "flex flex-wrap gap-2" ]
                        (List.map
                            (\code ->
                                li [ class "inline-flex items-center gap-1 rounded bg-bg-subtle px-2 py-1" ]
                                    [ span [ class "type-mono" ] [ text code ]
                                    , button
                                        [ type_ "button"
                                        , class "inline-flex h-7 w-7 items-center justify-center rounded text-text-muted hover:bg-white hover:text-brand focus-visible:ring-2 focus-visible:ring-brand"
                                        , onClick (RemoveItemCode index code)
                                        , attribute "aria-label" ("Poista tunnus " ++ code)
                                        , attribute "title" ("Poista tunnus " ++ code)
                                        ]
                                        [ FeatherIcons.x |> FeatherIcons.withSize 14 |> FeatherIcons.toHtml [ attribute "aria-hidden" "true" ] ]
                                    ]
                            )
                            item.codes
                        )
                , input
                    ([ id inputId
                     , type_ "search"
                     , value query
                     , onInput (SetSearchChanged index)
                     , placeholder "Hae settiä (esim. Millennium Falcon tai 6285)"
                     , attribute "autocomplete" "off"
                     , attribute "role" "combobox"
                     , attribute "aria-autocomplete" "list"
                     , attribute "aria-label" ("Hae settiä kohteelle: " ++ itemLabel)
                     , attribute "aria-controls" listId
                     , attribute "aria-expanded"
                        (if expanded then
                            "true"

                         else
                            "false"
                        )
                     , class inputClass
                     ]
                        ++ (if expanded then
                                [ attribute "aria-activedescendant" (inputId ++ "-option-" ++ String.fromInt activeSuggestionIndex) ]

                            else
                                []
                           )
                        ++ keyboardAttributes
                    )
                    []
                , status
                , suggestionsView
                , if Types.itemHasValidCodes item then
                    text ""

                  else
                    p [ class "type-caption text-brand-red" ] [ text "Setille ja vaihtoehtoiselle rakennelmalle vähintään yksi tunnus on pakollinen." ]
                ]
    in
    codesWidget


serviceCheckbox : Int -> List Service -> Service -> Html Msg
serviceCheckbox index chosen service =
    label [ class "inline-flex min-h-11 items-center gap-2 type-body-small" ]
        [ input [ type_ "checkbox", checked (List.member service chosen), onCheck (ToggleService index service) ] []
        , text (Types.serviceName service)
        ]


inputClass : String
inputClass =
    "block w-full rounded border border-border-default bg-white px-3 py-2 type-body focus-visible:ring-2 focus-visible:ring-brand"
