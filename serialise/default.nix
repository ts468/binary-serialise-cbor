{ mkDerivation, aeson, array, base, base16-bytestring
, base64-bytestring, binary, bytestring, cborg, containers, deepseq
, directory, filepath, ghc-prim, half, hashable, old-locale
, primitive, QuickCheck, quickcheck-instances, scientific, stdenv
, tasty, tasty-hunit, tasty-quickcheck, text, time
, unordered-containers, vector
}:
mkDerivation {
  pname = "serialise";
  version = "0.1.0.0";
  src = ./.;
  libraryHaskellDepends = [
    array base bytestring cborg containers ghc-prim half hashable
    old-locale primitive text time unordered-containers vector
  ];
  testHaskellDepends = [
    aeson array base base16-bytestring base64-bytestring binary
    bytestring cborg containers deepseq directory filepath ghc-prim
    half hashable QuickCheck quickcheck-instances scientific tasty
    tasty-hunit tasty-quickcheck text time unordered-containers vector
  ];
  homepage = "https://github.com/well-typed/cborg";
  description = "A binary serialisation library for Haskell values";
  license = stdenv.lib.licenses.bsd3;
}
