module MarkdownSafety exposing (safeUrl, safeWebUrl)

{-| Keep Markdown links and images limited to web, email, and relative URLs.
-}

import Char
import String


safeUrl : String -> Maybe String
safeUrl rawUrl =
    let
        url =
            String.trim rawUrl

        hasControlCharacters =
            String.any
                (\character ->
                    let
                        code =
                            Char.toCode character
                    in
                    code <= 31 || code == 127
                )
                rawUrl

        hasBackslash =
            String.contains "\\" url

        beforeColon =
            String.split ":" url |> List.head |> Maybe.withDefault ""

        colonIsSchemeDelimiter =
            String.contains ":" url
                && not (String.any (\character -> character == '/' || character == '?' || character == '#') beforeColon)

        allowedScheme =
            List.member (String.toLower beforeColon) [ "http", "https", "mailto" ]
    in
    if hasControlCharacters || hasBackslash || url == "" then
        Nothing

    else if colonIsSchemeDelimiter then
        if allowedScheme then
            Just url

        else
            Nothing

    else
        Just url


safeWebUrl : String -> Maybe String
safeWebUrl rawUrl =
    let
        url =
            String.trim rawUrl

        lowerUrl =
            String.toLower url

        hasWebScheme =
            String.startsWith "https://" lowerUrl || String.startsWith "http://" lowerUrl

        authority =
            url
                |> String.split "://"
                |> List.drop 1
                |> List.head
                |> Maybe.withDefault ""
                |> String.split "/"
                |> List.head
                |> Maybe.withDefault ""
                |> String.split "?"
                |> List.head
                |> Maybe.withDefault ""
                |> String.split "#"
                |> List.head
                |> Maybe.withDefault ""
    in
    if
        hasWebScheme
            && authority
            /= ""
            && not (String.any (\character -> Char.toCode character <= 32 || Char.toCode character == 127) authority)
    then
        safeUrl url

    else
        Nothing
