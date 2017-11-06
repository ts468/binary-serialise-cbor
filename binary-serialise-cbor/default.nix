{ mkDerivation, cborg, serialise, stdenv }:
mkDerivation {
  pname = "binary-serialise-cbor";
  version = "0.1.1.0";
  src = ./.;
  libraryHaskellDepends = [ cborg serialise ];
  description = "Yet Another Binary Serialisation Library (compatibility shim)";
  license = stdenv.lib.licenses.bsd3;
}
