/* Pin UxPlay's crypto wrappers to known answers produced with OpenSSL 3, so a
 * libcrypto change (BoringSSL upgrade, assembly off) cannot alter pairing. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "crypto.h"
#include "srp.h"

static void require(int condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}

static int matches(const unsigned char *data, int length, const char *expected) {
    char hex[1024];
    if (length * 2 + 1 > (int) sizeof hex) return 0;
    for (int i = 0; i < length; i++) snprintf(hex + i * 2, 3, "%02x", data[i]);
    return strcmp(hex, expected) == 0;
}

static void test_ciphers_and_digests(void) {
    unsigned char key[16], iv[16], in[64], out[64], back[64], tag[16];
    for (int i = 0; i < 16; i++) { key[i] = (unsigned char) i; iv[i] = (unsigned char) (0xa0 + i); }
    for (int i = 0; i < 64; i++) in[i] = (unsigned char) (i * 7);

    aes_ctx_t *ctr = aes_ctr_init(key, iv);
    aes_ctr_encrypt(ctr, in, out, 37);
    aes_ctr_encrypt(ctr, in + 37, out + 37, 27);
    aes_ctr_destroy(ctr);
    require(matches(out, 64, "5e1fdfebea3e224ff89c789a60fcf3e66ab5c1591b66e330f94e0e0ef127f802"
                             "44a389be86cebfef111de9535afab22c4a4f8c57ff22961446e9ba19abdaccb3"),
            "AES-128-CTR keeps its stream across partial blocks");

    aes_ctx_t *cbc = aes_cbc_init(key, iv, AES_ENCRYPT);
    aes_cbc_encrypt(cbc, in, out, 64);
    aes_cbc_destroy(cbc);
    require(matches(out, 64, "4b2756d41bfafaa9b2f4fe4a3d884724c9a629174fce9b8fdd9370d88d92cb31"
                             "b97d2ab3925c8cfa584c67b4be610eb4691752031dbaa520ae116f8a83c53dac"),
            "AES-128-CBC encrypts the known answer");
    cbc = aes_cbc_init(key, iv, AES_DECRYPT);
    aes_cbc_decrypt(cbc, out, back, 64);
    aes_cbc_destroy(cbc);
    require(memcmp(back, in, 64) == 0, "AES-128-CBC decrypts its output");

    int length = gcm_encrypt(in, 50, out, key, iv, tag);
    require(matches(out, length, "3e5e5858ab26fc642b5b7398510a027da1153eb3523e2588e4bf8f6647d85b83"
                                 "5b74b5b3de5d967da737237cd421a4be6c52")
            && matches(tag, 16, "789faf2bfdac8c6cc59022d96eeb7179"), "AES-128-GCM encrypts and tags");
    require(gcm_decrypt(out, length, back, key, iv, tag) == 50 && memcmp(back, in, 50) == 0,
            "AES-128-GCM decrypts its output");

    unsigned char digest[64];
    unsigned int digest_length = 0;
    sha_ctx_t *sha = sha_init();
    sha_update(sha, in, 64);
    sha_final(sha, digest, &digest_length);
    sha_destroy(sha);
    require(matches(digest, (int) digest_length,
                    "9f59bad22a6a8bda005caa01350372bf744703244db0aeb0446d8523012962ce"
                    "d1e49fd8ff703523938926a0dbbb023920b07cce073352920635bb28cad8e104"), "SHA-512");
    md5_ctx_t *md5 = md5_init();
    md5_update(md5, in, 64);
    md5_final(md5, digest, &digest_length);
    md5_destroy(md5);
    require(matches(digest, (int) digest_length, "a2fcb39a253b9b785b1f97518fa37683"), "MD5");
}

static void test_keys(void) {
    unsigned char ours[32], theirs[32], first[32], second[32], data[64], signature[64];
    for (int i = 0; i < 64; i++) data[i] = (unsigned char) i;
    x25519_key_t *a = x25519_key_generate(), *b = x25519_key_generate();
    x25519_key_get_raw(ours, a);
    x25519_key_get_raw(theirs, b);
    x25519_key_t *a_public = x25519_key_from_raw(ours), *b_public = x25519_key_from_raw(theirs);
    x25519_derive_secret(first, a, b_public);
    x25519_derive_secret(second, b, a_public);
    require(memcmp(first, second, 32) == 0, "X25519 peers derive the same secret");
    x25519_key_destroy(a); x25519_key_destroy(b); x25519_key_destroy(a_public); x25519_key_destroy(b_public);

    int result = 0;
    const char *keyfile = "airplay-crypto-test.pem";
    remove(keyfile);
    ed25519_key_t *saved = ed25519_key_generate("AA:BB:CC:DD:EE:FF", keyfile, &result);
    ed25519_key_t *loaded = ed25519_key_generate("AA:BB:CC:DD:EE:FF", keyfile, &result);
    ed25519_key_get_raw(ours, saved);
    ed25519_key_get_raw(theirs, loaded);
    remove(keyfile);
    require(memcmp(ours, theirs, 32) == 0, "Ed25519 identity survives its key file");
    ed25519_sign(signature, sizeof signature, data, sizeof data, saved);
    ed25519_key_t *verifier = ed25519_key_from_raw(ours);
    require(ed25519_verify(signature, sizeof signature, data, sizeof data, verifier), "Ed25519 verifies");
    signature[3] ^= 1;
    require(!ed25519_verify(signature, sizeof signature, data, sizeof data, verifier),
            "Ed25519 rejects a changed signature");
    ed25519_key_destroy(saved); ed25519_key_destroy(loaded); ed25519_key_destroy(verifier);
}

static void test_srp(void) {
    unsigned char salt[16], verifier[256], a[256], b[32];
    for (int i = 0; i < 16; i++) salt[i] = (unsigned char) (i * 3);
    for (int i = 0; i < 256; i++) { verifier[i] = (unsigned char) (i ^ 0x5a); a[i] = (unsigned char) (255 - i); }
    for (int i = 0; i < 32; i++) b[i] = (unsigned char) (i * 11);
    const unsigned char *public_b = NULL;
    int public_length = 0, session_length = 0;
    struct SRPVerifier *server = srp_verifier_new(SRP_SHA1, SRP_NG_2048, "Pair-Setup", salt, 16, verifier, 256,
                                                  a, 256, b, 32, &public_b, &public_length, NULL, NULL, 1);
    const unsigned char *session = srp_verifier_get_session_key(server, &session_length);
    require(matches(public_b, public_length,
                    "8eaa1b38e6915471dabe6e1c7661f76f6bd446053cd0ef7ba50e4cd9fb7e2319"
                    "fa32e0f26b5ae101744bb97b9f7a3156e4cbbf95232297b41ca161ad69d82275"
                    "580cb5423b47a9ba9901fdec29127b6eac42c62c45f3491d80b32926118ffc9d"
                    "351b0bb29b153725f4db0515c0cceb38cc7ef895ceef20e92b5a4c8cf0388cf0"
                    "22b058456d651cee1e881dffcbb3ac6b4bb00174797c74408b510a478a842e2c"
                    "5907bf71616a672d3e16e190990c34e1ebddbe3a801c309e08060cca22fed2a6"
                    "32e0d132568c1ab1de39634e080c532c6b6811de3226ca9759842e429fde9432"
                    "e33cd1a2d6ed9d978b380cf8e7c31503c08c0a646c635a5ab0bd130fce945414")
            && matches(session, session_length,
                       "d2db2ae2f540cd9da44280b93fbd258cb7a82f08b95c94a15d07654044215f37"
                       "e136a1b0b16a1e05"), "SRP-6a server key and session match the known answer");
    srp_verifier_delete(server);
}

int main(void) {
    test_ciphers_and_digests();
    test_keys();
    test_srp();
    return 0;
}
