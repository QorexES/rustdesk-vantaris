// Vantaris: verificación Ed25519 (RFC 8032) para las actualizaciones. Ver vantaris_ed25519.cpp.
#pragma once
#include <cstddef>

bool VantarisEd25519Verify(const unsigned char pk[32], const unsigned char* msg, size_t len,
                           const unsigned char sig[64]);
