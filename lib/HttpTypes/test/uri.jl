using Test, HttpTypes
using HttpTypes: as_str, InvalidUri, InvalidUriParts

const _MAX_LEN = 65534

kind(f) = try
    f()
    nothing
catch e
    e isa InvalidUri ? e.kind : e isa InvalidUriParts ? e.err.kind : rethrow()
end

# The crate's `test_parse!` macro: accessor checks, equality with the source string,
# clone equality, Display round trip, and equality with each alternative spelling.
function check_parse(orig, alt, checks::Pair...)
    u = Uri(orig)
    for (f, v) in checks
        @test isequal(f(u), v)
    end
    @test u == orig
    @test u == deepcopy(u)
    @test Uri(string(u)) == orig
    for a in alt
        @test u == a
        @test u == Uri(a)
    end
end

@testset "uri" begin

@testset "tests.rs" begin
    @testset "test_char_table" begin
        for (i, v) in enumerate(HttpTypes._U_URI_CHARS)
            v != 0 && @test i - 1 == v
        end
    end

    @testset "test_uri_parse_path_and_query" check_parse("/some/path/here?and=then&hello#and-bye", [],
        scheme => nothing, authority => nothing, path => "/some/path/here",
        query => "and=then&hello", host => nothing)
    @testset "test_uri_parse_absolute_form" check_parse("http://127.0.0.1:61761/chunks", [],
        scheme => Scheme("http"), authority => Authority("127.0.0.1:61761"), path => "/chunks",
        query => nothing, host => "127.0.0.1", port => Port("61761"))
    @testset "test_uri_parse_absolute_form_without_path" check_parse("https://127.0.0.1:61761",
        ["https://127.0.0.1:61761/"],
        scheme => Scheme("https"), authority => Authority("127.0.0.1:61761"), path => "/",
        query => nothing, host => "127.0.0.1", port => Port("61761"))
    @testset "test_uri_parse_asterisk_form" check_parse("*", [],
        scheme => nothing, authority => nothing, path => "*", query => nothing, host => nothing)
    @testset "test_uri_parse_authority_no_port" check_parse("localhost", ["LOCALHOST", "LocaLHOSt"],
        scheme => nothing, authority => Authority("localhost"), path => "", query => nothing,
        port => nothing, host => "localhost")
    @testset "test_uri_authority_only_one_character_issue_197" check_parse("S", [],
        scheme => nothing, authority => Authority("S"), path => "", query => nothing,
        port => nothing, host => "S")
    @testset "test_uri_parse_authority_form" check_parse("localhost:3000", ["localhosT:3000"],
        scheme => nothing, authority => Authority("localhost:3000"), path => "", query => nothing,
        host => "localhost", port => Port("3000"))
    @testset "test_uri_parse_absolute_with_default_port_http" check_parse("http://127.0.0.1:80",
        ["http://127.0.0.1:80/"],
        scheme => Scheme("http"), authority => Authority("127.0.0.1:80"), host => "127.0.0.1",
        path => "/", query => nothing, port => Port("80"))
    @testset "test_uri_parse_absolute_with_default_port_https" check_parse("https://127.0.0.1:443",
        ["https://127.0.0.1:443/"],
        scheme => Scheme("https"), authority => Authority("127.0.0.1:443"), host => "127.0.0.1",
        path => "/", query => nothing, port => Port("443"))
    @testset "test_uri_parse_fragment_questionmark" check_parse("http://127.0.0.1/#?", [],
        scheme => Scheme("http"), authority => Authority("127.0.0.1"), host => "127.0.0.1",
        path => "/", query => nothing, port => nothing)
    @testset "test_uri_parse_path_with_terminating_questionmark" check_parse("http://127.0.0.1/path?", [],
        scheme => Scheme("http"), authority => Authority("127.0.0.1"), path => "/path",
        query => "", port => nothing)
    @testset "test_uri_parse_absolute_form_with_empty_path_and_nonempty_query" check_parse(
        "http://127.0.0.1?foo=bar", [],
        scheme => Scheme("http"), authority => Authority("127.0.0.1"), path => "/",
        query => "foo=bar", port => nothing)
    @testset "test_uri_parse_absolute_form_with_empty_path_and_fragment_with_slash" check_parse(
        "http://127.0.0.1#foo/bar", [],
        scheme => Scheme("http"), authority => Authority("127.0.0.1"), path => "/",
        query => nothing, port => nothing)
    @testset "test_uri_parse_absolute_form_with_empty_path_and_fragment_with_questionmark" check_parse(
        "http://127.0.0.1#foo?bar", [],
        scheme => Scheme("http"), authority => Authority("127.0.0.1"), path => "/",
        query => nothing, port => nothing)
    long = "thequickbrownfoxjumpedoverthelazydogtofindthelargedangerousdragon.localhost"
    @testset "test_uri_parse_long_host_with_no_scheme" check_parse(long, [],
        scheme => nothing, authority => Authority(long), path => "", query => nothing, port => nothing)
    @testset "test_uri_parse_long_host_with_port_and_no_scheme" check_parse(long * ":1234", [],
        scheme => nothing, authority => Authority(long * ":1234"), path => "", query => nothing,
        port => Port("1234"))
    @testset "test_userinfo1" check_parse("http://a:b@127.0.0.1:1234/", [],
        scheme => Scheme("http"), authority => Authority("a:b@127.0.0.1:1234"), host => "127.0.0.1",
        path => "/", query => nothing, port => Port("1234"))
    @testset "test_userinfo2" check_parse("http://a:b@127.0.0.1/", [],
        scheme => Scheme("http"), authority => Authority("a:b@127.0.0.1"), host => "127.0.0.1",
        path => "/", query => nothing, port => nothing)
    @testset "test_userinfo3" check_parse("http://a@127.0.0.1/", [],
        scheme => Scheme("http"), authority => Authority("a@127.0.0.1"), host => "127.0.0.1",
        path => "/", query => nothing, port => nothing)
    @testset "test_userinfo_with_port" check_parse("user@localhost:3000", [],
        scheme => nothing, authority => Authority("user@localhost:3000"), path => "", query => nothing,
        host => "localhost", port => Port("3000"))
    @testset "test_userinfo_pass_with_port" check_parse("user:pass@localhost:3000", [],
        scheme => nothing, authority => Authority("user:pass@localhost:3000"), path => "",
        query => nothing, host => "localhost", port => Port("3000"))
    v6 = "[2001:0db8:85a3:0000:0000:8a2e:0370:7334]"
    @testset "test_ipv6" check_parse("http://$v6/", [],
        scheme => Scheme("http"), authority => Authority(v6), host => v6, path => "/",
        query => nothing, port => nothing)
    @testset "test_ipv6_shorthand" check_parse("http://[::1]/", [],
        scheme => Scheme("http"), authority => Authority("[::1]"), host => "[::1]", path => "/",
        query => nothing, port => nothing)
    @testset "test_ipv6_shorthand2" check_parse("http://[::]/", [],
        scheme => Scheme("http"), authority => Authority("[::]"), host => "[::]", path => "/",
        query => nothing, port => nothing)
    @testset "test_ipv6_shorthand3" check_parse("http://[2001:db8::2:1]/", [],
        scheme => Scheme("http"), authority => Authority("[2001:db8::2:1]"), host => "[2001:db8::2:1]",
        path => "/", query => nothing, port => nothing)
    @testset "test_ipv6_with_port" check_parse("http://$v6:8008/", [],
        scheme => Scheme("http"), authority => Authority("$v6:8008"), host => v6, path => "/",
        query => nothing, port => Port("8008"))
    @testset "test_percentage_encoded_path" check_parse("/echo/abcdefgh_i-j%20/abcdefg_i-j%20478", [],
        scheme => nothing, authority => nothing, host => nothing,
        path => "/echo/abcdefgh_i-j%20/abcdefg_i-j%20478", query => nothing, port => nothing)
    @testset "test_path_permissive" check_parse("/foo=bar|baz\\^~%", [], path => "/foo=bar|baz\\^~%")
    @testset "test_query_permissive" check_parse("/?foo={bar|baz}\\^`", [], query => "foo={bar|baz}\\^`")

    @testset "test_uri_parse_error" begin
        for s in ("http://", "htt:p//host", "hyper.rs/", "hyper.rs?key=val", "?key=val", "localhost/",
                  "localhost?key=val", "\0", "http://[::1", "http://::1]", "localhost:8080:3030", "@",
                  "http://username:password@/wut", "/?foo\rbar", "/?foo\nbar", "/?<", "/?>")
            @test_throws InvalidUri Uri(s)
            @test tryparse(Uri, s) === nothing
        end
    end

    @testset "test_max_uri_len" begin
        @test kind(() -> Uri("http://localhost/" * "a"^(70 * 1024))) === :TooLong
    end

    @testset "test_overflowing_scheme" begin
        @test kind(() -> Uri("a"^256 * "://localhost/")) === :SchemeTooLong
    end

    @testset "test_max_length_scheme" begin
        @test ncodeunits(scheme_str(Uri("a"^64 * "://localhost/"))) == 64
    end

    @testset "test_uri_to_path_and_query" begin
        for (s, want) in [("/", "/"), ("/foo?bar", "/foo?bar"), ("/foo?bar#nope", "/foo?bar"),
                          ("http://hyper.rs", "/"), ("http://hyper.rs/", "/"),
                          ("http://hyper.rs/path", "/path"), ("http://hyper.rs?query", "/?query"),
                          ("*", "*")]
            @test string(path_and_query(Uri(s))) == want
        end
    end

    @testset "test_authority_uri_parts_round_trip" begin
        s = "hyper.rs"
        u = Uri(s)
        @test u == s
        @test string(u) == s
        u2 = Uri(UriParts(u))
        @test u2 == s
        @test string(u2) == s
    end

    @testset "test_partial_eq_path_with_terminating_questionmark" begin
        @test Uri("/path?") == "/path"
    end
end

@testset "scheme.rs" begin
    @testset "scheme_eq_to_str" begin
        for s in ("http", "https", "ftp", "my+funky+scheme")
            @test Scheme(s) == s
        end
    end
    @testset "standard_scheme_is_case_insensitive" begin
        for (s, expected) in [("HTTP", Schemes.HTTP), ("hTtP", Schemes.HTTP), ("HTTPS", Schemes.HTTPS)]
            parsed = Scheme(s)
            @test parsed == expected
            @test as_str(parsed) == as_str(expected)
            @test parsed in Set([expected])
        end
    end
    @testset "invalid_scheme_is_error" begin
        @test_throws InvalidUri Scheme("my_funky_scheme")
        @test_throws InvalidUri Scheme([0xC0])
    end
end

@testset "port.rs" begin
    @testset "partialeq_port" begin
        @test Port("8080") == Port("8080")
    end
    @testset "partialeq_port_different_reprs" begin
        a, b = Port("8081"), Port(SubString("x8081", 2))
        @test a == b
        @test b == a
    end
    @testset "partialeq_u16" begin
        p = Port("8080")
        @test p == 8080
        @test 8080 == p
    end
    @testset "u16_from_port" begin
        @test UInt16(Port("8080")) === UInt16(8080)
    end
end

@testset "authority.rs" begin
    @testset "parse_empty_string_is_error" begin
        @test kind(() -> Authority("")) === :Empty
    end
    @testset "equal_to_self_of_same_authority" begin
        a1, a2 = Authority("example.com"), Authority("EXAMPLE.COM")
        @test a1 == a2
        @test a2 == a1
        @test hash(a1) == hash(a2)
    end
    @testset "not_equal_to_self_of_different_authority" begin
        a1, a2 = Authority("example.com"), Authority("test.com")
        @test a1 != a2
        @test a2 != a1
    end
    @testset "equates_with_a_str" begin
        a = Authority("example.com")
        @test a == "EXAMPLE.com"
        @test "EXAMPLE.com" == a
    end
    @testset "from_static_equates_with_a_str" begin
        @test Authority("example.com") == "example.com"
    end
    @testset "not_equal_with_a_str_of_a_different_authority" begin
        a = Authority("example.com")
        @test a != "test.com"
        @test "test.com" != a
    end
    @testset "equates_with_a_string" begin
        a = Authority("example.com")
        @test a == SubString("xEXAMPLE.com", 2)
        @test SubString("xEXAMPLE.com", 2) == a
    end
    @testset "equates_with_a_string_of_a_different_authority" begin
        a = Authority("example.com")
        @test a != SubString("xtest.com", 2)
        @test SubString("xtest.com", 2) != a
    end
    @testset "compares_to_self" begin
        a1, a2 = Authority("abc.com"), Authority("def.com")
        @test a1 < a2
        @test a2 > a1
    end
    @testset "compares_with_a_str" begin
        a = Authority("def.com")
        @test a < "ghi.com"
        @test "ghi.com" > a
        @test a > "abc.com"
        @test "abc.com" < a
        @test Authority("DEF.com") < "ghi.com"
    end
    @testset "compares_with_a_string" begin
        a = Authority("def.com")
        @test a < SubString("ghi.com")
        @test SubString("ghi.com") > a
        @test a > SubString("abc.com")
        @test SubString("abc.com") < a
    end
    @testset "allows_percent_in_userinfo" begin
        s = "a%2f:b%2f@example.com"
        @test Authority(s) == s
    end
    @testset "rejects_percent_in_hostname" begin
        @test kind(() -> Authority("example%2f.com")) === :InvalidAuthority
        @test kind(() -> Authority("a%2f:b%2f@example%2f.com")) === :InvalidAuthority
    end
    @testset "allows_percent_in_ipv6_address" begin
        s = "[fe80::1:2:3:4%25eth0]"
        @test Authority(s) == s
    end
    @testset "reject_obviously_invalid_ipv6_address" begin
        @test kind(() -> Authority("[0:1:2:3:4:5:6:7:8:9:10:11:12:13:14]")) === :InvalidAuthority
    end
    @testset "rejects_percent_outside_ipv6_address" begin
        @test kind(() -> Authority("1234%20[fe80::1:2:3:4]")) === :InvalidAuthority
        @test kind(() -> Authority("[fe80::1:2:3:4]%20")) === :InvalidAuthority
    end
    @testset "rejects_invalid_utf8" begin
        @test kind(() -> Authority([0xc0])) === :InvalidUriChar
        @test kind(() -> Authority(String([0xc0]))) === :InvalidUriChar
    end
    @testset "rejects_invalid_use_of_brackets" begin
        @test kind(() -> Authority("[]@[")) === :InvalidAuthority
        @test kind(() -> Authority("]o[")) === :InvalidAuthority
    end
    @testset "from_static_rejects_scheme_prefix" begin
        @test_throws InvalidUri Authority("https://127.0.0.1")
    end
    @testset "from_static_rejects_trailing_path" begin
        @test_throws InvalidUri Authority("example.com/path")
    end
    @testset "from_static_rejects_trailing_query" begin
        @test_throws InvalidUri Authority("example.com?query=1")
    end
    @testset "from_static_rejects_trailing_fragment" begin
        @test_throws InvalidUri Authority("example.com#frag")
    end
end

@testset "path.rs" begin
    pq(s) = PathAndQuery(s)
    @testset "equal_to_self_of_same_path" begin
        p1, p2 = pq("/hello/world&foo=bar"), pq("/hello/world&foo=bar")
        @test p1 == p2
        @test p2 == p1
        @test hash(p1) == hash(p2)
    end
    @testset "not_equal_to_self_of_different_path" begin
        p1, p2 = pq("/hello/world&foo=bar"), pq("/world&foo=bar")
        @test p1 != p2
        @test p2 != p1
    end
    @testset "equates_with_a_str" begin
        p = pq("/hello/world&foo=bar")
        @test p == "/hello/world&foo=bar"
        @test "/hello/world&foo=bar" == p
    end
    @testset "not_equal_with_a_str_of_a_different_path" begin
        p = pq("/hello/world&foo=bar")
        @test p != "/hello&foo=bar"
        @test "/hello&foo=bar" != p
    end
    @testset "equates_with_a_string" begin
        p = pq("/hello/world&foo=bar")
        @test p == SubString("/hello/world&foo=bar")
        @test SubString("/hello/world&foo=bar") == p
    end
    @testset "not_equal_with_a_string_of_a_different_path" begin
        p = pq("/hello/world&foo=bar")
        @test p != SubString("/hello&foo=bar")
        @test SubString("/hello&foo=bar") != p
    end
    @testset "compares_to_self" begin
        p1, p2 = pq("/a/world&foo=bar"), pq("/b/world&foo=bar")
        @test p1 < p2
        @test p2 > p1
    end
    @testset "compares_with_a_str" begin
        p = pq("/b/world&foo=bar")
        @test p < "/c/world&foo=bar"
        @test "/c/world&foo=bar" > p
        @test p > "/a/world&foo=bar"
        @test "/a/world&foo=bar" < p
    end
    @testset "compares_with_a_string" begin
        p = pq("/b/world&foo=bar")
        @test p < SubString("/c/world&foo=bar")
        @test SubString("/c/world&foo=bar") > p
        @test p > SubString("/a/world&foo=bar")
        @test SubString("/a/world&foo=bar") < p
    end
    @testset "ignores_valid_percent_encodings" begin
        @test path(pq("/a%20b?r=1")) == "/a%20b"
        @test query(pq("/a/b?qr=%31")) == "qr=%31"
    end
    @testset "ignores_invalid_percent_encodings" begin
        @test path(pq("/a%%b?r=1")) == "/a%%b"
        @test path(pq("/aaa%")) == "/aaa%"
        @test path(pq("/aaa%?r=1")) == "/aaa%"
        @test path(pq("/aa%2")) == "/aa%2"
        @test path(pq("/aa%2?r=1")) == "/aa%2"
        @test query(pq("/a/b?qr=%3")) == "qr=%3"
    end
    @testset "allow_utf8_in_path" begin
        @test path(pq("/🍕")) == "/🍕"
    end
    @testset "allow_utf8_in_query" begin
        @test query(pq("/test?pizza=🍕")) == "pizza=🍕"
    end
    @testset "rejects_invalid_utf8_in_path" begin
        @test_throws InvalidUri pq([UInt8('/'), 0xFF])
        @test_throws InvalidUri pq([UInt8('/'), 0xed, 0xa0, 0x80])
    end
    @testset "rejects_invalid_utf8_in_query" begin
        @test_throws InvalidUri pq([UInt8('/'), UInt8('a'), UInt8('?'), 0xFF])
    end
    @testset "rejects_empty_string" begin
        @test_throws InvalidUri pq("")
    end
    @testset "requires_starting_with_slash" begin
        @test_throws InvalidUri pq("sneaky")
    end
    @testset "rejects_del_in_path" begin
        @test_throws InvalidUri pq([UInt8('/'), 0x7F])
    end
    @testset "rejects_del_in_query" begin
        @test_throws InvalidUri pq([UInt8('/'), UInt8('a'), UInt8('?'), 0x7F])
    end
    @testset "rejects_too_long_path_and_query" begin
        @test kind(() -> pq("/" * "a"^_MAX_LEN * "?query")) === :TooLong
    end
    @testset "accepts_max_length_path_and_query" begin
        p = pq("/" * "a"^(_MAX_LEN - 2) * "?")
        @test ncodeunits(as_str(p)) == _MAX_LEN
        @test query(p) == ""
    end
    @testset "json_is_fine" begin
        @test path(pq("/{\"bread\":\"baguette\"}")) == "/{\"bread\":\"baguette\"}"
    end
end

@testset "builder.rs" begin
    @testset "build_from_str" begin
        u = Uri(scheme=Schemes.HTTP, authority="hyper.rs", path_and_query="/foo?a=1")
        @test scheme_str(u) == "http"
        @test host(authority(u)) == "hyper.rs"
        @test path(u) == "/foo"
        @test query(u) == "a=1"
    end
    @testset "build_from_string" begin
        for i in 1:9
            u = Uri(path_and_query="/foo?a=$i")
            @test path(u) == "/foo"
            @test query(u) == "a=$i"
        end
    end
    @testset "build_from_string_ref" begin
        for i in 1:9
            u = Uri(path_and_query=SubString("x/foo?a=$i", 2))
            @test path(u) == "/foo"
            @test query(u) == "a=$i"
        end
    end
    @testset "build_from_empty_path_and_query" begin
        u = Uri(scheme=Schemes.HTTP, authority="localhost:8080", path_and_query="")
        @test u == "http://localhost:8080"
        @test path(u) == "/"
    end
    @testset "empty_path_and_query_remains_strict" begin
        @test tryparse(PathAndQuery, "") === nothing
    end
    @testset "authority_form_path_and_query_remains_strict" begin
        @test_throws InvalidUri Uri(path_and_query="localhost:8080")
    end
    @testset "build_from_uri" begin
        original = Uri()
        p = UriParts(original)
        @test Uri(scheme=p.scheme, authority=p.authority, path_and_query=p.path_and_query) == original
        @test Uri(p) == original
    end
    @testset "build_star_for_http2" begin
        u = Uri(scheme="https", authority="example.com", path_and_query="*")
        @test scheme(u) == Schemes.HTTPS
        @test host(u) == "example.com"
        @test path(u) == "*"
        @test string(u) == "https://example.com"
    end
end

@testset "julia surface" begin
    @test uri"/a?b" == "/a?b"
    @test_throws LoadError eval(:(@uri_str "/a b"))
    @test kind(() -> Uri(UriParts(scheme=Schemes.HTTP))) === :AuthorityMissing
    @test kind(() -> Uri(UriParts(authority=Authority("a"), path_and_query=PathAndQuery("/")))) === :SchemeMissing
    @test sprint(showerror, InvalidUri(:TooLong)) == "uri too long"
    @test hash(Uri("HTTP://Example.com/a?b")) == hash(Uri("http://example.com/a?b"))
    @test Uri("HTTP://Example.com/a?b") == Uri("http://example.com/a?b")
    @test Uri("http://a/b") != Uri("http://a/c")
    @test Uri("/x") == Uri(PathAndQuery("/x"))
    @test Uri("h:1") == Uri(Authority("h:1"))
    @test Uri(collect(codeunits("/v?q"))) == "/v?q"
    @test port_u16(Uri("http://h:65535/")) == 65535
    @test port(Uri("http://h:65536/")) === nothing
    @test port(Uri("http://[::1]/")) === nothing
    @test string(Port("+80")) == "80" && as_str(Port("+80")) == "+80"
    @test kind(() -> Port("")) === :InvalidPort
    @test sprint(show, Schemes.HTTP) == "Schemes.HTTP" && repr(Scheme("ftp")) == "Scheme(\"ftp\")"
    @test sprint(show, Port("8")) == "Port(8)"
    s = "/p?q=1"
    u = GC.@preserve s HttpTypes.uri_from_target(pointer(s), 2, pointer(s) + 3, 3)
    @test u == "/p?q=1" && query(u) == "q=1"
    u = GC.@preserve s HttpTypes.uri_from_target(pointer(s), 2, C_NULL, -1)
    @test u == "/p" && query(u) === nothing
    @test GC.@preserve(s, Uri(pointer(s), 2)) == "/p"
end

end
