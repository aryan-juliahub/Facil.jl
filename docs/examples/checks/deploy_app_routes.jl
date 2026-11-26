@test status(example.app(Request(Methods.GET, "/health", ""))) == 200
@test status(example.app(Request(Methods.GET, "/nope", ""))) == 404
