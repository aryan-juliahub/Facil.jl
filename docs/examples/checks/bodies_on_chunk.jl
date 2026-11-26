# needs: SHA
using SHA
data = repeat("0123456789", 200_000)
r = http(ex, "POST", "/"; headers = ["X-Upload-Id" => "u1"], body = data)
@test r.status == 200
@test r.body == "2000000 bytes, sha256 $(bytes2hex(sha256(data)))\n"
@test http(ex, "POST", "/"; body = "abc").status == 400
@test http(ex, "GET", "/").status == 400
@test isempty(example.UPLOADS)
