{ mkDerivation, aeson, aeson-pretty, base, bytestring, cborg
, cborg-json, filepath, scientific, stdenv, text
, unordered-containers, vector
}:
mkDerivation {
  pname = "cbor-tool";
  version = "0.1.0.0";
  src = ./.;
  isLibrary = false;
  isExecutable = true;
  executableHaskellDepends = [
    aeson aeson-pretty base bytestring cborg cborg-json filepath
    scientific text unordered-containers vector
  ];
  homepage = "https://github.com/well-typed/cborg";
  description = "A tool for manipulating CBOR";
  license = stdenv.lib.licenses.bsd3;
}
