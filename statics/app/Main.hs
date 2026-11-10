module Main (main) where

-- | Deliberate no-op: public list data is served at runtime from PocketBase.
-- Keep this executable and its build target as part of the sibling-app scaffold.
main :: IO ()
main = putStrLn "No static data to generate; set lists are served by PocketBase."
