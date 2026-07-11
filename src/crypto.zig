const std = @import("std");
const runtime = @import("runtime.zig");

const AEAD = std.crypto.aead.chacha_poly.XChaCha20Poly1305;

pub const key_length = AEAD.key_length;
pub const nonce_length = AEAD.nonce_length;
pub const tag_length = AEAD.tag_length;

pub const Key = [key_length]u8;

pub const format_version = "insh:v1";

pub const DecryptError = error{
    BlobTooSmall,
    AuthenticationFailed,
};

pub fn generateKey() Key {
    var key: Key = undefined;
    runtime.io().random(&key);
    return key;
}

pub fn encrypt(gpa: std.mem.Allocator, plaintext: []const u8, key: Key) ![]u8 {
    var nonce: [nonce_length]u8 = undefined;
    runtime.io().random(&nonce);

    const out = try gpa.alloc(u8, nonce_length + plaintext.len + tag_length);
    errdefer gpa.free(out);

    @memcpy(out[0..nonce_length], &nonce);

    var tag: [tag_length]u8 = undefined;
    AEAD.encrypt(
        out[nonce_length..][0..plaintext.len],
        &tag,
        plaintext,
        format_version,
        nonce,
        key,
    );
    @memcpy(out[nonce_length + plaintext.len ..], &tag);
    return out;
}

pub fn decrypt(gpa: std.mem.Allocator, blob: []const u8, key: Key) ![]u8 {
    if (blob.len < nonce_length + tag_length) return DecryptError.BlobTooSmall;
    const ct_len = blob.len - nonce_length - tag_length;

    var nonce: [nonce_length]u8 = undefined;
    @memcpy(&nonce, blob[0..nonce_length]);

    var tag: [tag_length]u8 = undefined;
    @memcpy(&tag, blob[nonce_length + ct_len ..]);

    const plaintext = try gpa.alloc(u8, ct_len);
    AEAD.decrypt(
        plaintext,
        blob[nonce_length..][0..ct_len],
        tag,
        format_version,
        nonce,
        key,
    ) catch {
        gpa.free(plaintext);
        return DecryptError.AuthenticationFailed;
    };
    return plaintext;
}

test "roundtrip" {
    const gpa = std.testing.allocator;
    const key = generateKey();
    const plaintext = "hello world, env=SECRET_VALUE";

    const ct = try encrypt(gpa, plaintext, key);
    defer gpa.free(ct);

    const pt = try decrypt(gpa, ct, key);
    defer gpa.free(pt);

    try std.testing.expectEqualStrings(plaintext, pt);
}

test "decrypt fails with wrong key" {
    const gpa = std.testing.allocator;
    const key = generateKey();
    var wrong_key = key;
    wrong_key[0] +%= 1;

    const ct = try encrypt(gpa, "secret", key);
    defer gpa.free(ct);

    try std.testing.expectError(DecryptError.AuthenticationFailed, decrypt(gpa, ct, wrong_key));
}

test "decrypt fails on tampered ciphertext" {
    const gpa = std.testing.allocator;
    const key = generateKey();

    const ct = try encrypt(gpa, "secret", key);
    defer gpa.free(ct);
    ct[nonce_length] +%= 1;

    try std.testing.expectError(DecryptError.AuthenticationFailed, decrypt(gpa, ct, key));
}

test "decrypt rejects too-small blob" {
    const gpa = std.testing.allocator;
    const key = generateKey();
    const tiny = [_]u8{0} ** 8;
    try std.testing.expectError(DecryptError.BlobTooSmall, decrypt(gpa, &tiny, key));
}
