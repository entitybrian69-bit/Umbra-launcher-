// Tests for the JSON reader: every kind of value, every escape, the number
// grammar, nesting, and the errors a model file must not be able to sneak past.
import std;
import core.json;
import test.harness;

fn run_json() {
    // A document with every kind of value and both containers.
    {
        let src = "{\"n\": 42, \"neg\": -7, \"f\": 1.5, \"e\": 2e3, \"t\": true, \"fa\": false, \"z\": null, \"s\": \"hi\", \"arr\": [1, 2, 3], \"obj\": {\"k\": \"v\"}}";
        let root = json_parse(src);
        check(root >= 0, "a complete document parses");
        check_i64(json_kind(root), J_OBJ as i64, "the root is an object");
        check_i64(json_child_count(root), 10, "ten members");
        check_i64(json_get_int(root, "n"), 42, "an integer member reads back");
        check_i64(json_get_int(root, "neg"), -7, "a negative integer reads back");
        check_f64(json_num(json_get(root, "f")), 1.5, "a fraction reads back");
        check_f64(json_num(json_get(root, "e")), 2000.0, "an exponent reads back");
        check(json_get_bool(root, "t"), "true reads back");
        check(!json_get_bool(root, "fa"), "false reads back");
        check_i64(json_kind(json_get(root, "z")), J_NULL as i64, "null is null");
        check_bytes(json_get_str(root, "s"), "hi", "a string reads back");
        let arr = json_get(root, "arr");
        check_i64(json_kind(arr), J_ARR as i64, "an array is an array");
        check_i64(json_child_count(arr), 3, "the array has three elements");
        check_i64(json_int(json_at(arr, 2)), 3, "the third element is 3");
        let o = json_get(root, "obj");
        check_bytes(json_get_str(o, "k"), "v", "a nested object member reads back");
        // A missing member is -1, not a zero value.
        check_i64(json_get(root, "absent"), -1, "an absent member is -1");
    }

    // Whitespace anywhere between tokens.
    {
        let root = json_parse(" \n\t{ \"a\" : [ 1 ,\r\n 2 ] } \n ");
        check(root >= 0, "whitespace around tokens is fine");
        check_i64(json_child_count(json_get(root, "a")), 2, "two elements after whitespace");
    }

    // Escapes, including a BMP escape and a surrogate pair.
    {
        let root = json_parse("\"a\\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti\\u00e9j\\ud83d\\ude00\"");
        check(root >= 0, "an escaped string parses");
        let s = json_str(root);
        // a"b\c/d<bs>e<ff>f\ng\rh\ti<e9>j<emoji>
        check_i64(s.len as i64, 24, "the escaped string has 24 bytes");
        check_i64(s[1] as i64, 34, "escaped quote");
        check_i64(s[3] as i64, 92, "escaped backslash");
        check_i64(s[5] as i64, 47, "escaped slash");
        check_i64(s[7] as i64, 8, "escaped backspace");
        check_i64(s[9] as i64, 12, "escaped form feed");
        check_i64(s[11] as i64, 10, "escaped newline");
        check_i64(s[13] as i64, 13, "escaped carriage return");
        check_i64(s[15] as i64, 9, "escaped tab");
        // i = 16, then U+00E9 is two bytes, then j, then U+1F600 is four bytes.
        check_i64(s[17] as i64, 0xC3, "first byte of U+00E9");
        check_i64(s[18] as i64, 0xA9, "second byte of U+00E9");
        check_i64(s[19] as i64, 106, "the letter after the escape");
        check_i64(s[20] as i64, 0xF0, "first byte of U+1F600");
        check_i64(s[23] as i64, 0x80, "last byte of U+1F600");
    }

    // Numbers: shapes that are legal, and the integer flag.
    {
        let root = json_parse("[0, -0, 10, 1.25, -1.25, 1e2, 1E+2, 1e-2, 123456789]");
        check(root >= 0, "a list of numbers parses");
        check_f64(json_num(json_at(root, 0)), 0.0, "zero");
        check_f64(json_num(json_at(root, 2)), 10.0, "ten");
        check_f64(json_num(json_at(root, 3)), 1.25, "a fraction");
        check_f64(json_num(json_at(root, 4)), -1.25, "a negative fraction");
        check_f64(json_num(json_at(root, 5)), 100.0, "an exponent");
        check_f64(json_num(json_at(root, 6)), 100.0, "an exponent with a plus");
        check_f64(json_num(json_at(root, 7)), 0.01, "a negative exponent");
        check_i64(json_int(json_at(root, 8)), 123456789, "a large integer");
    }

    // A realistic blockstate document, shaped like the game's own files.
    {
        let src = "{\"variants\":{\"facing=north\":{\"model\":\"minecraft:block/oak_log\"},\"facing=south\":{\"model\":\"minecraft:block/oak_log\",\"y\":180}}}";
        let root = json_parse(src);
        check(root >= 0, "a blockstate-shaped document parses");
        let variants = json_get(root, "variants");
        let north = json_get(variants, "facing=north");
        check_bytes(json_get_str(north, "model"), "minecraft:block/oak_log", "the model name reads back");
        let south = json_get(variants, "facing=south");
        check_i64(json_get_int(south, "y"), 180, "the rotation reads back");
    }

    // Errors: each of these must be refused, with a reason.
    check(json_parse("{\"a\":1,}") < 0, "a trailing comma in an object is refused");
    check(json_parse("[1,2,]") < 0, "a trailing comma in an array is refused");
    check(json_parse("{\"a\" 1}") < 0, "a missing colon is refused");
    check(json_parse("{a:1}") < 0, "an unquoted member name is refused");
    check(json_parse("\"unterminated") < 0, "an unterminated string is refused");
    check(json_parse("\"bad \\q escape\"") < 0, "an unknown escape is refused");
    check(json_parse("\"raw\nnewline\"") < 0, "a raw newline in a string is refused");
    check(json_parse("[1,2") < 0, "an unterminated array is refused");
    check(json_parse("{\"a\":1} extra") < 0, "trailing bytes are refused");
    check(json_parse("") < 0, "an empty document is refused");
    check(json_parse("01") < 0, "a leading zero is refused");
    check(json_parse("1.") < 0, "a fraction with no digits is refused");
    check(json_parse("1e") < 0, "an exponent with no digits is refused");
    check(json_parse("tru") < 0, "a truncated literal is refused");
    check(json_parse("\"\\ud83d\"") < 0, "a lone high surrogate is refused");
    check(json_parse("\"\\udc00\"") < 0, "a lone low surrogate is refused");
    // Deep nesting is refused rather than overflowing the stack.
    {
        var src2: u8[>..] = [];
        for i in 60 { src2.push(91); }  // sixty '['
        for i in 60 { src2.push(93); }
        check(json_parse(src2) < 0, "sixty levels of array are refused");
    }
    // ...but a sane depth is accepted.
    {
        var src3: u8[>..] = [];
        for i in 20 { src3.push(91); }
        for i in 20 { src3.push(93); }
        check(json_parse(src3) >= 0, "twenty levels of array are accepted");
    }

    // The error text names a byte offset, which is what makes a bad file
    // debuggable instead of just "parse failed".
    let bad = json_parse("{\"a\": 1,}");
    check(bad < 0, "the broken document is refused");
    check(json_error().len > 0, "the refusal carries a reason");

    test_summary("json");
}
