# [Changelog](@id changelog)

This page shows the project's changelog, the record of what each version
added, changed and fixed. The source is
[`CHANGELOG.md`](https://github.com/aryan-juliahub/Facil.jl/blob/main/CHANGELOG.md)
in the repository; what follows is that file as it was when this site was
built.

```@eval
using Markdown
text = read(joinpath(Main.EXAMPLES, "..", "..", "CHANGELOG.md"), String)
Markdown.parse(replace(text, r"^# Changelog\n"m => ""; count = 1))
```
