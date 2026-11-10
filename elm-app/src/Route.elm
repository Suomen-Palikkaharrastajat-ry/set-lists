module Route exposing (Route(..), matchesListId, parseUrl, toHref)

{-| Hash routes for the login home, public list links, and owned-list editor.
-}

import Url exposing (Url)


type Route
    = Home
    | PublicList String
    | EditList (Maybe String)
    | NotFound


matchesListId : String -> Route -> Bool
matchesListId id route =
    case route of
        PublicList currentId ->
            currentId == id

        EditList (Just currentId) ->
            currentId == id

        _ ->
            False


parseUrl : Url -> Route
parseUrl url =
    let
        fragment =
            Maybe.withDefault "/" url.fragment

        path =
            String.split "?" fragment |> List.head |> Maybe.withDefault "/"

        segments =
            String.split "/" path |> List.filter ((/=) "")
    in
    case segments of
        [] ->
            Home

        [ "lists", "new" ] ->
            EditList Nothing

        [ "lists", id, "edit" ] ->
            EditList (Just id)

        [ id ] ->
            PublicList id

        _ ->
            NotFound


toHref : Route -> String
toHref route =
    case route of
        Home ->
            "#/"

        PublicList id ->
            "#/" ++ id

        EditList Nothing ->
            "#/lists/new"

        EditList (Just id) ->
            "#/lists/" ++ id ++ "/edit"

        NotFound ->
            "#/404"
