{ mkDerivation, aeson, aeson-pretty, base, cborg, scientific
, stdenv, text, unordered-containers, vector
}:
mkDerivation {
  pname = "cborg-json";
  version = "0.1.0.0";
  src = ./.;
  libraryHaskellDepends = [
    aeson aeson-pretty base cborg scientific text unordered-containers
    vector
  ];
  homepage = "https://github.com/well-typed/cborg";
  description = "A library for encoding JSON as CBOR";
  license = stdenv.lib.licenses.bsd3;
}
