{ mkDerivation, array, base, bytestring, containers, ghc-prim, half
, integer-gmp, primitive, stdenv, text
}:
mkDerivation {
  pname = "cborg";
  version = "0.1.1.0";
  src = ./.;
  libraryHaskellDepends = [
    array base bytestring containers ghc-prim half integer-gmp
    primitive text
  ];
  description = "Concise Binary Object Representation";
  license = stdenv.lib.licenses.bsd3;
}
