using HttpTypes.header: HOST, ACCEPT, LOCATION, VIA, SET_COOKIE, VARY, CONTENT_TYPE

const STD = [getfield(header, k) for k in (
    :ACCEPT, :ACCEPT_CHARSET, :ACCEPT_ENCODING, :ACCEPT_LANGUAGE, :ACCEPT_RANGES,
    :ACCESS_CONTROL_ALLOW_CREDENTIALS, :ACCESS_CONTROL_ALLOW_HEADERS, :ACCESS_CONTROL_ALLOW_METHODS,
    :ACCESS_CONTROL_ALLOW_ORIGIN, :ACCESS_CONTROL_EXPOSE_HEADERS, :ACCESS_CONTROL_MAX_AGE,
    :ACCESS_CONTROL_REQUEST_HEADERS, :ACCESS_CONTROL_REQUEST_METHOD, :AGE, :ALLOW, :ALT_SVC,
    :AUTHORIZATION, :CACHE_CONTROL, :CACHE_STATUS, :CDN_CACHE_CONTROL, :CONNECTION,
    :CONTENT_DISPOSITION, :CONTENT_ENCODING, :CONTENT_LANGUAGE, :CONTENT_LENGTH, :CONTENT_LOCATION,
    :CONTENT_RANGE, :CONTENT_SECURITY_POLICY, :CONTENT_SECURITY_POLICY_REPORT_ONLY, :CONTENT_TYPE,
    :COOKIE, :DNT, :DATE, :ETAG, :EXPECT, :EXPIRES, :FORWARDED, :FROM, :HOST, :IF_MATCH,
    :IF_MODIFIED_SINCE, :IF_NONE_MATCH, :IF_RANGE, :IF_UNMODIFIED_SINCE, :LAST_MODIFIED, :LINK,
    :LOCATION, :MAX_FORWARDS, :ORIGIN, :PRAGMA, :PROXY_AUTHENTICATE, :PROXY_AUTHORIZATION,
    :PUBLIC_KEY_PINS, :PUBLIC_KEY_PINS_REPORT_ONLY, :RANGE, :REFERER, :REFERRER_POLICY, :RETRY_AFTER,
    :SERVER, :SET_COOKIE, :STRICT_TRANSPORT_SECURITY, :TE, :TRAILER, :TRANSFER_ENCODING, :USER_AGENT,
    :UPGRADE, :UPGRADE_INSECURE_REQUESTS, :VARY, :VIA, :WARNING, :WWW_AUTHENTICATE,
    :X_CONTENT_TYPE_OPTIONS, :X_DNS_PREFETCH_CONTROL, :X_FRAME_OPTIONS, :X_XSS_PROTECTION)]

custom_std(n) = [HeaderName(string(as_str(STD[i%length(STD)+1]), "-", i)) for i in 0:n-1]

function remove_all_values(headers, key)
    e = entry(headers, key)
    return e isa OccupiedEntry ? remove_entry_mult!(e)[2] : HeaderValue[]
end

function remove_values(headers, key)
    e = entry(headers, key)
    return e isa OccupiedEntry ? remove_entry!(e)[2] : nothing
end

function six_headers()
    headers = HeaderMap()
    insert!(headers, VIA, "1.1 example.com")
    insert!(headers, SET_COOKIE, "cookie_1=value 1")
    append!(headers, SET_COOKIE, "cookie_2=value 2")
    append!(headers, VIA, "1.1 other.com")
    append!(headers, SET_COOKIE, "cookie_3=value 3")
    insert!(headers, VARY, "*")
    return headers
end

@testset "header_map::smoke" begin
    headers = HeaderMap()
    @test get(headers, "hello", nothing) === nothing
    name = HeaderName("hello")

    e = entry(headers, name)
    @test e isa VacantEntry
    insert!(e, "world")
    @test get(headers, "hello", nothing) !== nothing

    e = entry(headers, name)
    @test e isa OccupiedEntry
    @test e[] == "world"
    append!(e, "zomg")
    @test collect(e) == ["world", "zomg"]
end

@testset "header_map::reserve_over_capacity" begin
    headers = HeaderMap{UInt32}(32)
    @test_throws MaxSizeReached sizehint!(headers, 50_000)
end

@testset "header_map::with_capacity_max" begin
    @test HeaderMap{UInt32}(24_576) isa HeaderMap{UInt32}
end

@testset "header_map::with_capacity_overflow" begin
    @test_throws MaxSizeReached HeaderMap{UInt32}(24_577)
end

@testset "header_map::extend_size_hint_above_capacity" begin
    name = from_static(HeaderName, "h")
    value = from_static(HeaderValue, "0")
    map = HeaderMap((name => value for _ in 1:24_577))
    @test length(map) == 24_577
    @test keys_len(map) == 1
end

@testset "header_map::reserve_overflow" begin
    headers = HeaderMap{UInt32}(0)
    @test_throws MaxSizeReached sizehint!(headers, typemax(Int))
end

@testset "header_map::drain" begin
    headers = HeaderMap()
    insert!(headers, HeaderName("hello"), "world")
    d = drain!(headers)
    @test length(d) == 1
    @test as_str(d[1].first) == "hello"
    @test d[1].second == "world"
    @test isempty(headers)

    insert!(headers, HeaderName("hello"), "world")
    insert!(headers, HeaderName("zomg"), "bar")
    append!(headers, HeaderName("hello"), "world2")
    d = drain!(headers)
    @test length(d) == 3
    @test as_str(d[1].first) == "hello" && d[1].second == "world"
    @test d[2].first === nothing && d[2].second == "world2"
    @test as_str(d[3].first) == "zomg" && d[3].second == "bar"
end

@testset "header_map::drain_entry" begin
    headers = HeaderMap()
    insert!(headers, HeaderName("hello"), "world")
    insert!(headers, HeaderName("zomg"), "foo")
    append!(headers, HeaderName("hello"), "world2")
    insert!(headers, HeaderName("more"), "words")
    append!(headers, HeaderName("more"), "insertions")
    @test length(headers) == 5

    e = entry(headers, "hello")
    @test e isa OccupiedEntry
    vals = insert_mult!(e, "wat")
    @test length(vals) == 2
    @test vals[1] == "world"
    @test vals[2] == "world2"
    @test length(headers) == 5 - 2 + 1
end

@testset "header_map::insert_mult_with_more_than_two_values" begin
    headers = HeaderMap()
    for val in ("a", "b", "c", "d")
        append!(headers, "hello", val)
    end
    append!(headers, "other", "x")
    append!(headers, "other", "y")

    e = entry(headers, "hello")
    @test e isa OccupiedEntry
    @test insert_mult!(e, "new") == ["a", "b", "c", "d"]

    @test length(headers) == 3
    @test get_all(headers, "hello") == ["new"]
    @test get_all(headers, "other") == ["x", "y"]
    append!(headers, "hello", "again")
    @test get_all(headers, "hello") == ["new", "again"]
end

@testset "header_map::eq" begin
    a = HeaderMap()
    b = HeaderMap()
    @test a == b
    insert!(a, HeaderName("hello"), "world")
    @test a != b
    insert!(b, HeaderName("hello"), "world")
    @test a == b
    insert!(a, HeaderName("foo"), "bar")
    append!(a, HeaderName("foo"), "baz")
    @test a != b
    insert!(b, HeaderName("foo"), "bar")
    @test a != b
    append!(b, HeaderName("foo"), "baz")
    @test a == b
    append!(a, HeaderName("a"), "a")
    append!(a, HeaderName("a"), "b")
    append!(b, HeaderName("a"), "b")
    append!(b, HeaderName("a"), "a")
    @test a != b
end

@testset "header_map::into_header_name" begin
    m = HeaderMap()
    insert!(m, HOST, "localhost")
    insert!(m, ACCEPT, "*/*")
    insert!(m, "connection", "keep-alive")
    append!(m, LOCATION, "/")
    append!(m, VIA, "bob")
    append!(m, "transfer-encoding", "chunked")
    @test length(m) == 6
end

@testset "header_map::as_header_name" begin
    m = HeaderMap()
    v = HeaderValue("localhost")
    insert!(m, HOST, v)
    @test get(m, "host", nothing) == v
    @test get(m, HOST, nothing) == v
    s = String("host")
    @test get(m, s, nothing) == v
    @test get(m, SubString(s, 1), nothing) == v
end

@testset "header_map::insert_all_std_headers" begin
    m = HeaderMap()
    for (i, hdr) in enumerate(STD)
        insert!(m, hdr, as_str(hdr))
        for j in 1:i
            @test m[STD[j]] == as_str(STD[j])
        end
        if i != 1
            for j in i+1:length(STD)
                @test get(m, STD[j], nothing) === nothing
            end
        end
    end
end

@testset "header_map::insert_79_custom_std_headers" begin
    h = HeaderMap()
    hdrs = custom_std(79)
    for (i, hdr) in enumerate(hdrs)
        insert!(h, hdr, as_str(hdr))
        for j in 1:i
            @test h[hdrs[j]] == as_str(hdrs[j])
        end
        for j in i+1:length(hdrs)
            @test get(h, hdrs[j], nothing) === nothing
        end
    end
end

@testset "header_map::append_multiple_values" begin
    map = HeaderMap()
    append!(map, CONTENT_TYPE, "json")
    append!(map, CONTENT_TYPE, "html")
    append!(map, CONTENT_TYPE, "xml")
    @test collect(get_all(map, CONTENT_TYPE)) == ["json", "html", "xml"]
end

@testset "header_map::get_invalid" begin
    headers = HeaderMap()
    insert!(headers, "foo", "bar")
    @test get(headers, "Evil\r\nKey", nothing) === nothing
end

@testset "header_map::insert_invalid" begin
    headers = HeaderMap()
    @test_throws InvalidHeaderName insert!(headers, "evil\r\nfoo", "bar")
end

@testset "header_map::value_htab" begin
    @test from_static(HeaderValue, "hello\tworld") isa HeaderValue
    @test HeaderValue("hello\tworld") isa HeaderValue
end

@testset "header_map::remove_multiple_a" begin
    headers = six_headers()
    @test length(headers) == 6
    @test remove!(headers, SET_COOKIE) == HeaderValue("cookie_1=value 1")
    @test length(headers) == 3
    @test remove!(headers, VIA) == HeaderValue("1.1 example.com")
    @test length(headers) == 1
    @test remove!(headers, VARY) == HeaderValue("*")
    @test length(headers) == 0
end

@testset "header_map::remove_multiple_b" begin
    headers = six_headers()
    @test length(headers) == 6
    @test remove!(headers, VARY) == HeaderValue("*")
    @test length(headers) == 5
    @test remove!(headers, VIA) == HeaderValue("1.1 example.com")
    @test length(headers) == 3
    @test remove!(headers, SET_COOKIE) == HeaderValue("cookie_1=value 1")
    @test length(headers) == 0
end

@testset "header_map::remove_entry_multi_0" begin
    headers = HeaderMap()
    @test length(remove_all_values(headers, SET_COOKIE)) == 0
    @test length(headers) == 0
end

@testset "header_map::remove_entry_multi_0_others" begin
    headers = HeaderMap()
    insert!(headers, VIA, "1.1 example.com")
    append!(headers, VIA, "1.1 other.com")
    @test length(remove_all_values(headers, SET_COOKIE)) == 0
    @test length(headers) == 2
end

@testset "header_map::remove_entry_multi_1" begin
    headers = HeaderMap()
    insert!(headers, SET_COOKIE, "cookie_1=value 1")
    @test length(remove_all_values(headers, SET_COOKIE)) == 1
    @test length(headers) == 0
end

@testset "header_map::remove_entry_multi_1_other" begin
    headers = HeaderMap()
    insert!(headers, SET_COOKIE, "cookie_1=value 1")
    insert!(headers, VIA, "1.1 example.com")
    @test length(remove_all_values(headers, SET_COOKIE)) == 1
    @test length(headers) == 1
    @test length(remove_all_values(headers, VIA)) == 1
    @test length(headers) == 0
end

@testset "header_map::remove_entry_multi_2" begin
    headers = HeaderMap()
    insert!(headers, SET_COOKIE, "cookie_1=value 1")
    append!(headers, SET_COOKIE, "cookie_2=value 2")
    @test length(remove_all_values(headers, SET_COOKIE)) == 2
    @test length(headers) == 0
end

@testset "header_map::remove_entry_multi_3" begin
    headers = HeaderMap()
    insert!(headers, SET_COOKIE, "cookie_1=value 1")
    append!(headers, SET_COOKIE, "cookie_2=value 2")
    append!(headers, SET_COOKIE, "cookie_3=value 3")
    @test length(remove_all_values(headers, SET_COOKIE)) == 3
    @test length(headers) == 0
end

@testset "header_map::remove_entry_multi_3_others" begin
    headers = six_headers()
    @test length(remove_all_values(headers, SET_COOKIE)) == 3
    @test length(headers) == 3
    @test length(remove_all_values(headers, VIA)) == 2
    @test length(headers) == 1
    @test length(remove_all_values(headers, VARY)) == 1
    @test length(headers) == 0
end

@testset "header_map::remove_entry_3_others_a" begin
    headers = six_headers()
    @test length(headers) == 6
    @test remove_values(headers, SET_COOKIE) == HeaderValue("cookie_1=value 1")
    @test length(headers) == 3
    @test remove_values(headers, VIA) == HeaderValue("1.1 example.com")
    @test length(headers) == 1
    @test remove_values(headers, VARY) == HeaderValue("*")
    @test length(headers) == 0
end

@testset "header_map::remove_entry_3_others_b" begin
    headers = six_headers()
    @test length(headers) == 6
    @test remove_values(headers, VARY) == HeaderValue("*")
    @test length(headers) == 5
    @test remove_values(headers, VIA) == HeaderValue("1.1 example.com")
    @test length(headers) == 3
    @test remove_values(headers, SET_COOKIE) == HeaderValue("cookie_1=value 1")
    @test length(headers) == 0
end

# Rust checks size_hint bounds while stepping; here the length is exact up front.
@testset "header_map::iter_size_hint" begin
    for counts in (Int[], [1], [3], [1, 1], [3, 1, 2])
        headers = HeaderMap()
        for (i, count) in enumerate(counts)
            name = HeaderName(codeunits("header-$(i-1)"))
            for _ in 1:count
                append!(headers, name, from_static(HeaderValue, "x"))
            end
        end
        len = length(headers)
        @test len == sum(counts; init=0)
        @test count(_ -> true, headers) == len
        @test length(collect(headers)) == len
        @test length(values(headers)) == len
        @test length(collect(keys(headers))) == length(counts) == keys_len(headers)
    end
end

@testset "map::skip_duplicates_during_key_iteration" begin
    map = HeaderMap()
    append!(map, "a", from_static(HeaderValue, "a"))
    append!(map, "a", from_static(HeaderValue, "b"))
    @test count(_ -> true, keys(map)) == keys_len(map)
end

@testset "header_map::reserve" begin
    headers = HeaderMap{Int}()
    @test length(headers) == 0
    requested_cap = 8
    reserve!(headers, requested_cap)
    p = pointer(headers.names)
    for i in 0:requested_cap-1
        insert!(headers, HeaderName("h$i"), i)
    end
    @test pointer(headers.names) == p
    @test keys_len(headers) == requested_cap
end

@testset "header_map::drain_drop_immediately" begin
    headers = HeaderMap()
    insert!(headers, "hello", "world")
    insert!(headers, "zomg", "bar")
    append!(headers, "hello", "world2")
    d = drain!(headers)
    @test length(d) == 3
    @test count(p -> p.first !== nothing, d) == 2
    @test isempty(headers)
end

@testset "header_map::drain_forget" begin
    headers = HeaderMap()
    insert!(headers, "hello", "world")
    insert!(headers, "zomg", "bar")
    @test length(headers) == 2
    d = drain!(headers)
    @test length(d) == 2
    @test length(headers) == 0
end

@testset "header_map::ensure_miri_sharedreadonly_not_violated" begin
    headers = HeaderMap()
    insert!(headers, from_static(HeaderName, "chunky-trailer"), from_static(HeaderValue, "header data"))
    @test first(headers) == (hn"chunky-trailer" => hv"header data")
end

@testset "header_map::ensure_miri_itermut_not_violated" begin
    headers = HeaderMap{UInt32}()
    insert!(headers, hn"hello", 1)
    insert!(headers, hn"zomg", 2)
    vals = values(headers)
    vals[1] += 10
    vals[2] += 20
    @test headers[hn"hello"] == 11 && headers[hn"zomg"] == 22
end

@testset "header_map::ensure_miri_valueitermut_not_violated" begin
    headers = HeaderMap{UInt32}()
    insert!(headers, hn"hello", 1)
    append!(headers, hn"hello", 2)
    append!(headers, hn"hello", 3)
    e = entry(headers, hn"hello")
    @test e isa OccupiedEntry
    vals = values(e)
    vals[1] += 10
    vals[2] += 20
    @test get_all(headers, "hello") == [11, 22, 3]
end

@testset "map::test_headermap_adaptive_hashing" begin
    keys_ = [HeaderName("x-header-$i") for i in 0:519]
    map = HeaderMap{Int}(2500)
    for (i, k) in enumerate(keys_)
        or_insert!(entry(map, k), i)
    end
    for (i, k) in enumerate(keys_)
        @test map[k] == i
    end
    @test keys_len(map) == 520
end

# A small seeded generator, so the test needs no Random.
mutable struct FuzzRng
    s::UInt64
end
function fuzz_next!(r::FuzzRng)
    x = r.s
    x ⊻= x << 13
    x ⊻= x >> 7
    x ⊻= x << 17
    r.s = x
    return x
end
fuzz_range(r::FuzzRng, lo::Int, hi::Int) = lo + Int(fuzz_next!(r) % UInt64(hi - lo))
fuzz_ratio(r::FuzzRng, d::Int) = fuzz_range(r, 0, d) == 0

const FUZZ_CHARS = b"ABCDEFGHIJKLMNOPQRSTUVabcdefghilpqrstuvwxyz----"
fuzz_string(r, lo, hi) = String([FUZZ_CHARS[fuzz_range(r, 1, length(FUZZ_CHARS) + 1)] for _ in lo:hi-1])
fuzz_name(r) = fuzz_ratio(r, 2) ? HttpTypes.standard_header(fuzz_range(r, 1, 82)) : HeaderName(fuzz_string(r, 1, 25))
fuzz_value(r) = HeaderValue(codeunits(fuzz_string(r, 0, 70)))

# Reference model: names in insertion order, a removal moves the last name into
# the freed slot (the crate's swap-remove), values of one name kept together.
struct AltMap
    order::Vector{HeaderName}
    vals::Dict{HeaderName,Vector{HeaderValue}}
end
AltMap() = AltMap(HeaderName[], Dict{HeaderName,Vector{HeaderValue}}())

function alt_pick(m::AltMap, weight, r)
    existing = fuzz_ratio(r, abs(weight))
    weight < 0 && (existing = !existing)
    (existing && !isempty(m.order)) && return m.order[fuzz_range(r, 1, length(m.order) + 1)]
    return fuzz_name(r)
end
function alt_insert!(m::AltMap, k, v)
    old = haskey(m.vals, k) ? first(m.vals[k]) : nothing
    old === nothing && push!(m.order, k)
    m.vals[k] = [v]
    return old
end
function alt_remove!(m::AltMap, k)
    haskey(m.vals, k) || return nothing
    i = findfirst(==(k), m.order)
    last = pop!(m.order)
    i <= length(m.order) && (m.order[i] = last)
    return first(pop!(m.vals, k))
end
function alt_append!(m::AltMap, k, v)
    had = haskey(m.vals, k)
    had || push!(m.order, k)
    push!(get!(m.vals, k, HeaderValue[]), v)
    return had
end
function alt_identical(m::AltMap, h::HeaderMap)
    keys_len(h) == length(m.vals) || return false
    for (k, vs) in m.vals
        get(h, k, nothing) == first(vs) || return false
        collect(get_all(h, k)) == vs || return false
    end
    return collect(h) == [k => v for k in m.order for v in m.vals[k]]
end

@testset "header_map_fuzz::header_map_fuzz" begin
    nsteps = 0
    for seed in 1:60
        r = FuzzRng(0x9e3779b97f4a7c15 * UInt64(seed))
        num = fuzz_range(r, 5, 500)
        wi, wr, wa = fuzz_range(r, 1, 10), fuzz_range(r, 1, 10), fuzz_range(r, 1, 10)
        alt = AltMap()
        h = HeaderMap()
        ok = true
        for _ in 1:num
            n = fuzz_range(r, 0, wi + wr + wa)
            if n < wi
                k = alt_pick(alt, 4, r)
                v = fuzz_value(r)
                ok &= insert!(h, k, v) == alt_insert!(alt, k, v)
            elseif n < wi + wr
                k = alt_pick(alt, -4, r)
                collect(get_all(h, k))
                ok &= remove!(h, k) == alt_remove!(alt, k)
            else
                k = alt_pick(alt, -5, r)
                v = fuzz_value(r)
                ok &= append!(h, k, v) == alt_append!(alt, k, v)
            end
            ok &= alt_identical(alt, h)
            nsteps += 1
        end
        @test ok
    end
    @test nsteps > 5000
end
