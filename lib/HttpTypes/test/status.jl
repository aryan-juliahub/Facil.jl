status_code(n) = StatusCode(n)

@testset "status_code::from_bytes" begin
    for ok in ("100", "101", "199", "200", "250", "299", "321", "399", "499", "599", "600", "999")
        @test tryparse(StatusCode, codeunits(ok)) !== nothing
        @test StatusCode(Vector{UInt8}(ok)) == parse(Int, ok)
    end
    for not_ok in ("0", "00", "10", "40", "99", "000", "010", "099", "1000", "1999")
        @test tryparse(StatusCode, codeunits(not_ok)) === nothing
        @test_throws InvalidStatusCode StatusCode(Vector{UInt8}(not_ok))
        @test_throws InvalidStatusCode StatusCode(not_ok)
    end
end

@testset "status_code::equates_with_u16" begin
    status = StatusCode(0x00c8)
    @test 0x00c8 == status
    @test status == 0x00c8
end

@testset "status_code::roundtrip" begin
    for s in 100:999
        sstr = string(s)
        status = StatusCode(codeunits(sstr))
        @test s == UInt16(status)
        @test sstr == as_str(status)
    end
end

@testset "status_code::is_informational" begin
    @test is_informational(status_code(100))
    @test is_informational(status_code(199))
    @test !is_informational(status_code(200))
end

@testset "status_code::is_success" begin
    @test is_success(status_code(200))
    @test is_success(status_code(299))
    @test !is_success(status_code(199))
    @test !is_success(status_code(300))
end

@testset "status_code::is_redirection" begin
    @test is_redirection(status_code(300))
    @test is_redirection(status_code(399))
    @test !is_redirection(status_code(299))
    @test !is_redirection(status_code(400))
end

@testset "status_code::is_client_error" begin
    @test is_client_error(status_code(400))
    @test is_client_error(status_code(499))
    @test !is_client_error(status_code(399))
    @test !is_client_error(status_code(500))
end

@testset "status_code::is_server_error" begin
    @test is_server_error(status_code(500))
    @test is_server_error(status_code(599))
    @test !is_server_error(status_code(499))
    @test !is_server_error(status_code(600))
end

@testset "status::doc examples" begin
    @test StatusCode(200) === StatusCodes.OK
    @test StatusCodes.NOT_FOUND == 404
    @test is_success(StatusCodes.OK)
    @test_throws InvalidStatusCode StatusCode(99)
    @test_throws InvalidStatusCode StatusCode(1000)
    @test tryparse(StatusCode, 0) === nothing
    @test as_str(StatusCodes.OK) == "200"
    @test as_str(StatusCode(999)) == "999"
    @test canonical_reason(StatusCodes.OK) == "OK"
    @test canonical_reason(StatusCode(999)) === nothing
    @test StatusCode() === StatusCodes.OK
    @test string(StatusCodes.NOT_FOUND) == "404 Not Found"
    @test string(StatusCode(599)) == "599 <unknown status code>"
    @test repr(StatusCodes.NOT_FOUND) == "StatusCodes.NOT_FOUND" && repr(StatusCode(599)) == "StatusCode(599)"
end
