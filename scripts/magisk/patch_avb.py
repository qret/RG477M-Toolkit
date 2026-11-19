# -*- coding: utf-8 -*-
"""
Patch AVB0 HashDescriptor for init_boot inside both init_boot_<slot>_magisk.img
and stock vbmeta_<slot>.img -> vbmeta_<slot>_magisk.img, then re-sign vbmeta
with the standard AOSP testkey_rsa2048 key used by Anbernic RG477M V1.32.
"""
import hashlib
import struct
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Official AOSP AVB testkey_rsa2048 (external/avb/test/data/testkey_rsa2048.pem)
AOSP_TESTKEY_N = 0xc65551dd3224a2e00ebc7efdbda2538058697ef54a4087959054593d55caff36341afae1e0902a1a32685bf3dfad0bf9b1d0f7eaab471f76be1b984b67a362fadfe6b5f8ee73165fb8b182de4989d53dd7a842998175c8d8847bbd54a8226444bc3406103c89c2d1f32c036591b1a0d1c82156159948202774ef017a76a50b6bfde3faed0df90f7a41fa76053749fe344f4b0149e498f7898ecd36aa391da97d5d6b5a52d17569a8df7cde1c1bf9d9195bb7474cb9702eade5d6887ced926e460810b576033e09ac4db62ccd1200bdd4a703d31b910823365b11feaf5969b33c8824372d61bac599511897f92342969f872ecdb24d5fa924f245dae26526264d
AOSP_TESTKEY_D = 0xbe90981a0ae5fcc18027497590d1f99d6655e730d469705d1ad290f4480cc66f545d6015cc6978aab72862c1ce773cfc6c08374d79c8dac8831d8c95573d3c0b853aee3a0312fdba7781c816c15df85075782c95c6386004fa36d2d216c304c8ae74e6268fa46656c869cfd1b5cd909240d3171da5ac118917e7d5e9cf3a01dfce2746e97642012dc3350d47d5e5a7382d2412e4dd200292fb0d990fc35bc2161d72e0f2f2e7d4bcd52767b7075e87e0ca04d93087c6a7cc82bd372034512688247a742e42c1617af613a3f989c874966af560ccc1c6f48e66f9e7a91785b2863d58e16c8a02e308fbd747017fe1ecbb7c5c50900a1e436e4546cc6af7e2c581
AOSP_TESTKEY_E = 65537
ASN1_SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


def rsa2048_pkcs1_v15_sign(digest32: bytes) -> bytes:
    assert len(digest32) == 32
    pad_len = 256 - 3 - len(ASN1_SHA256_PREFIX) - 32
    em = b"\x00\x01" + (b"\xff" * pad_len) + b"\x00" + ASN1_SHA256_PREFIX + digest32
    sig_int = pow(int.from_bytes(em, "big"), AOSP_TESTKEY_D, AOSP_TESTKEY_N)
    return sig_int.to_bytes(256, "big")


def rsa2048_pkcs1_v15_verify(sig256: bytes, digest32: bytes, pub_n: int) -> bool:
    pad_len = 256 - 3 - len(ASN1_SHA256_PREFIX) - 32
    expected = b"\x00\x01" + (b"\xff" * pad_len) + b"\x00" + ASN1_SHA256_PREFIX + digest32
    dec = pow(int.from_bytes(sig256, "big"), AOSP_TESTKEY_E, pub_n).to_bytes(256, "big")
    return dec == expected


def patch_hash_descriptor_in_aux(aux: bytearray, desc_off: int, desc_sz: int, target_part: str, new_img_sz: int, new_digest: bytes | None) -> tuple[bytes, bytes]:
    pos = desc_off
    end = desc_off + desc_sz
    while pos + 16 <= end:
        tag, nbytes = struct.unpack(">QQ", aux[pos:pos+16])
        body_start = pos + 16
        if tag == 2:  # AvbHashDescriptor
            pn_len, salt_len, dig_len, _ = struct.unpack(">IIII", aux[body_start+40:body_start+56])
            off = body_start + 116
            pn = bytes(aux[off:off+pn_len]).decode("utf-8", errors="ignore")
            if pn == target_part:
                salt = bytes(aux[off+pn_len : off+pn_len+salt_len])
                if new_digest is not None:
                    struct.pack_into(">Q", aux, body_start, new_img_sz)
                    aux[off+pn_len+salt_len : off+pn_len+salt_len+dig_len] = new_digest
                cur_dig = bytes(aux[off+pn_len+salt_len : off+pn_len+salt_len+dig_len])
                return salt, cur_dig
        pos += 16 + nbytes
    raise RuntimeError(f"AvbHashDescriptor for '{target_part}' not found")


def patch_images(init_boot_magisk_path: str, stock_vbmeta_path: str, out_vbmeta_path: str) -> None:
    with open(init_boot_magisk_path, "rb") as f:
        ib = bytearray(f.read())
    with open(stock_vbmeta_path, "rb") as f:
        vb = bytearray(f.read())

    # 1. Read AVBf footer at end of init_boot_magisk
    footer = ib[-64:]
    magic, maj, min_v, orig_sz, vb_off, vb_sz = struct.unpack(">4sIIQQQ", footer[:36])
    if magic != b"AVBf":
        raise RuntimeError(f"Missing AVBf footer in {init_boot_magisk_path}")

    # 2. Extract salt from stock vbmeta init_boot descriptor
    vb_hdr = bytearray(vb[:256])
    auth_sz, aux_sz = struct.unpack(">QQ", vb_hdr[12:28])
    hash_off, hash_sz, sig_off, sig_sz = struct.unpack(">QQQQ", vb_hdr[32:64])
    pk_off, pk_sz = struct.unpack(">QQ", vb_hdr[64:80])
    desc_off, desc_sz = struct.unpack(">QQ", vb_hdr[96:112])

    vb_aux = bytearray(vb[256 + auth_sz : 256 + auth_sz + aux_sz])
    salt, _ = patch_hash_descriptor_in_aux(vb_aux, desc_off, desc_sz, "init_boot", orig_sz, None)

    # 3. Compute new SHA256(salt + ib[:orig_sz])
    new_digest = hashlib.sha256(salt + bytes(ib[:orig_sz])).digest()

    # 4. Update internal AVB0 inside init_boot_magisk
    ib_vb = bytearray(ib[vb_off : vb_off + vb_sz])
    ib_auth_sz, ib_aux_sz = struct.unpack(">QQ", ib_vb[12:28])
    ib_desc_off, ib_desc_sz = struct.unpack(">QQ", ib_vb[96:112])
    ib_aux = bytearray(ib_vb[256 + ib_auth_sz : 256 + ib_auth_sz + ib_aux_sz])
    patch_hash_descriptor_in_aux(ib_aux, ib_desc_off, ib_desc_sz, "init_boot", orig_sz, new_digest)
    ib_vb[256 + ib_auth_sz : 256 + ib_auth_sz + ib_aux_sz] = ib_aux
    ib[vb_off : vb_off + vb_sz] = ib_vb
    with open(init_boot_magisk_path, "wb") as f:
        f.write(ib)

    # 5. Update stock vbmeta aux with new init_boot size & digest, keep flags=0 and all other descriptors intact
    patch_hash_descriptor_in_aux(vb_aux, desc_off, desc_sz, "init_boot", orig_sz, new_digest)
    vb_digest = hashlib.sha256(bytes(vb_hdr) + bytes(vb_aux)).digest()
    vb_sig = rsa2048_pkcs1_v15_sign(vb_digest)

    vb_auth = bytearray(vb[256 : 256 + auth_sz])
    vb_auth[hash_off : hash_off + hash_sz] = vb_digest
    vb_auth[sig_off : sig_off + sig_sz] = vb_sig

    vb[256 : 256 + auth_sz] = vb_auth
    vb[256 + auth_sz : 256 + auth_sz + aux_sz] = vb_aux

    # 6. Self-verify RSA signature against embedded public key in vbmeta aux
    pk = vb_aux[pk_off : pk_off + pk_sz]
    pub_n = int.from_bytes(pk[8:8+256], "big")
    if not rsa2048_pkcs1_v15_verify(vb_sig, vb_digest, pub_n):
        raise RuntimeError("RSA-2048 self-verification failed on patched vbmeta!")

    with open(out_vbmeta_path, "wb") as f:
        f.write(vb)

    print(f"[ OK ] AVB patched & verified: init_boot orig_sz={hex(orig_sz)}, digest={new_digest.hex()[:16]}..., vbmeta_sig={vb_sig.hex()[:16]}...")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: patch_avb.py <init_boot_magisk.img> <stock_vbmeta.img> <out_vbmeta_magisk.img>")
        sys.exit(1)
    patch_images(sys.argv[1], sys.argv[2], sys.argv[3])
