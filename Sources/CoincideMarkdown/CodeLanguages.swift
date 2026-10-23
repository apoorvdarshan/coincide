import Foundation

/// Lexical rules for one fence language. The scanner in `CodeHighlight` reads these;
/// markup, CSS, diff, INI and Markdown use dedicated line or tag scanners.
struct CodeLanguage: Sendable {
    enum Mode: Sendable { case code, markup, css, diff, ini, markdown }
    let id: String, label: String
    var aliases: [String] = []
    var mode: Mode = .code
    var lineComments: [String] = []
    var blockComments: [[String]] = []
    var strings: [String] = ["\"", "'"]
    var multilineStrings: [String] = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    var constants: Set<String> = ["true", "false", "null"]
    var builtins: Set<String> = []
    var caseInsensitive = false
    var capitalizedTypes = false
    var variables: Set<UInt16> = []
    var attributes: Set<UInt16> = []
    var preprocessor = false
    var keys = false
    var lineKeywords = false
    var targets = false
    var symbols = false
    var identifierExtras: Set<UInt16> = []
    var charLiterals = false
    var rawStrings = false
    var macros = false
    var hashAttributes = false
    var stringPrefixes: Set<UInt16> = []
    var metaMarkers: [String] = []
    var jsxTags = false
    var hashNeedsBoundary = false
}

enum CodeLanguages {
    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }
    private static func units(_ text: String) -> Set<UInt16> { Set(text.utf16) }

    private static let cKeywords = "auto break case const continue default do else enum extern for goto if inline register restrict return signed sizeof static struct switch typedef union unsigned volatile while _Bool _Complex _Atomic _Noreturn _Static_assert _Alignas _Alignof _Generic _Thread_local"
    private static let cTypes = "char double float int long short void bool size_t ssize_t ptrdiff_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t FILE wchar_t"
    private static let jsKeywords = "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield as"
    private static let tsKeywords = jsKeywords + " implements interface package private protected public enum type namespace declare abstract readonly keyof infer is satisfies override accessor module asserts unique"
    private static let tsTypes = "string number boolean any unknown never object symbol bigint void"
    private static let shellKeywords = "if then else elif fi case esac for select while until do done in function time coproc return exit break continue local declare export readonly unset shift source alias set trap eval exec end begin and or not"
    private static let shellBuiltins = "echo printf cd pwd ls cat grep rg sed awk find xargs mkdir rm cp mv touch chmod chown ln curl wget git gh npm npx yarn pnpm bun node deno python python3 pip pip3 brew swift xcodebuild xcrun make cmake cargo go docker kubectl sudo test read wait kill head tail sort uniq wc tar unzip open ssh scp env which"

    static let all: [CodeLanguage] = {
        var list: [CodeLanguage] = []
        func add(_ language: CodeLanguage) { list.append(language) }
        add(.init(id: "bash", label: "Bash", aliases: ["sh", "shell", "zsh", "fish", "ksh", "shellscript", "shell-session", "console", "terminal", "command"], lineComments: ["#"],
                  keywords: words(shellKeywords), constants: ["true", "false"], builtins: words(shellBuiltins), variables: units("$"), hashNeedsBoundary: true))
        add(.init(id: "c", label: "C", aliases: ["h"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], keywords: words(cKeywords),
                  types: words(cTypes), constants: ["true", "false", "NULL"], preprocessor: true, charLiterals: true))
        add(.init(id: "cpp", label: "C++", aliases: ["c++", "cc", "cxx", "hpp", "hh", "hxx", "h++", "cuda"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""],
                  keywords: words(cKeywords + " alignas alignof and asm catch class constexpr consteval constinit decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast static_assert static_cast template this thread_local throw try typeid typename using virtual co_await co_return co_yield concept requires override final"),
                  types: words(cTypes + " std string vector map unordered_map set array optional unique_ptr shared_ptr auto char8_t char16_t char32_t"), constants: ["true", "false", "nullptr", "NULL"],
                  capitalizedTypes: true, preprocessor: true, charLiterals: true))
        add(.init(id: "objc", label: "Objective-C", aliases: ["objective-c", "objectivec", "objc++", "objective-cpp", "m", "mm"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""],
                  keywords: words(cKeywords + " self super id instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull in out inout bycopy byref oneway"),
                  types: words(cTypes + " BOOL NSInteger NSUInteger CGFloat SEL IMP Class"), constants: ["YES", "NO", "nil", "Nil", "NULL", "true", "false"],
                  capitalizedTypes: true, attributes: units("@"), preprocessor: true, charLiterals: true))
        add(.init(id: "csharp", label: "C#", aliases: ["cs", "c#"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], multilineStrings: ["\"\"\""],
                  keywords: words("abstract as base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly ref return sealed sizeof stackalloc static struct switch this throw try typeof unchecked unsafe using virtual volatile while async await var dynamic get set init record when where yield nameof global partial required with"),
                  types: words("bool byte char decimal double float int long object sbyte short string uint ulong ushort void nint nuint"), capitalizedTypes: true, preprocessor: true, charLiterals: true))
        add(.init(id: "css", label: "CSS", mode: .css, blockComments: [["/*", "*/"]]))
        add(.init(id: "scss", label: "SCSS", aliases: ["sass", "less"], mode: .css, lineComments: ["//"], blockComments: [["/*", "*/"]]))
        add(.init(id: "dart", label: "Dart", lineComments: ["//"], blockComments: [["/*", "*/"]], multilineStrings: ["\"\"\"", "'''"],
                  keywords: words("abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for get hide if implements import in interface is late library mixin new on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield base"),
                  types: words("int double num String bool List Map Set Future Stream Object Iterable"), capitalizedTypes: true, attributes: units("@")))
        add(.init(id: "diff", label: "Diff", aliases: ["patch", "udiff"], mode: .diff))
        add(.init(id: "dockerfile", label: "Dockerfile", aliases: ["docker", "containerfile"], lineComments: ["#"],
                  keywords: words("from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell"),
                  caseInsensitive: true, variables: units("$"), lineKeywords: true, hashNeedsBoundary: true))
        add(.init(id: "elixir", label: "Elixir", aliases: ["ex", "exs"], lineComments: ["#"], multilineStrings: ["\"\"\"", "'''"],
                  keywords: words("after alias and catch cond def defdelegate defexception defguard defimpl defmacro defmacrop defmodule defp defprotocol defstruct do else end fn for if import in not or quote raise receive require rescue reraise super throw try unless unquote use when with"),
                  constants: ["true", "false", "nil"], capitalizedTypes: true, attributes: units("@"), symbols: true, identifierExtras: units("?!")))
        add(.init(id: "go", label: "Go", aliases: ["golang"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], multilineStrings: ["`"],
                  keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
                  types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any comparable"),
                  constants: ["true", "false", "nil", "iota"], builtins: words("append cap clear close complex copy delete imag len make max min new panic print println real recover"), charLiterals: true))
        add(.init(id: "graphql", label: "GraphQL", aliases: ["gql"], lineComments: ["#"], strings: ["\""], multilineStrings: ["\"\"\""],
                  keywords: words("query mutation subscription fragment on type interface union enum input scalar schema extend implements directive repeatable"),
                  capitalizedTypes: true, variables: units("$"), attributes: units("@")))
        add(.init(id: "haskell", label: "Haskell", aliases: ["hs"], lineComments: ["--"], blockComments: [["{-", "-}"]], strings: ["\""],
                  keywords: words("case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where qualified as hiding forall mdo family"),
                  constants: ["True", "False", "Nothing", "Just", "Left", "Right"], capitalizedTypes: true, charLiterals: true))
        add(.init(id: "html", label: "HTML", aliases: ["htm", "xhtml"], mode: .markup))
        add(.init(id: "java", label: "Java", lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], multilineStrings: ["\"\"\""],
                  keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp super switch synchronized this throw throws transient try void volatile while var record sealed permits yield"),
                  types: words("boolean byte char double float int long short String Object Integer Long Double Boolean List Map Set"), capitalizedTypes: true, attributes: units("@"), charLiterals: true))
        add(.init(id: "javascript", label: "JavaScript", aliases: ["js", "mjs", "cjs", "node", "javascriptreact"], lineComments: ["//"], blockComments: [["/*", "*/"]], multilineStrings: ["`"],
                  keywords: words(jsKeywords), constants: ["true", "false", "null", "undefined", "NaN", "Infinity"], capitalizedTypes: true, attributes: units("@"), identifierExtras: units("$")))
        add(.init(id: "jsx", label: "JSX", lineComments: ["//"], blockComments: [["/*", "*/"]], multilineStrings: ["`"], keywords: words(jsKeywords),
                  constants: ["true", "false", "null", "undefined", "NaN", "Infinity"], capitalizedTypes: true, attributes: units("@"), identifierExtras: units("$"), jsxTags: true))
        add(.init(id: "json", label: "JSON", aliases: ["jsonc", "json5", "jsonl", "geojson", "webmanifest"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], keys: true))
        add(.init(id: "kotlin", label: "Kotlin", aliases: ["kt", "kts"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], multilineStrings: ["\"\"\""],
                  keywords: words("as break class continue do else for fun if in interface is object package return super this throw try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg value"),
                  types: words("Int Long Short Byte Double Float Boolean Char String Unit Any Nothing List Map Set Array"), capitalizedTypes: true, attributes: units("@"), charLiterals: true))
        add(.init(id: "lua", label: "Lua", lineComments: ["--"], blockComments: [["--[[", "]]"], ["[[", "]]"]],
                  keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"), constants: ["true", "false", "nil"],
                  builtins: words("print pairs ipairs require type tostring tonumber select error assert pcall setmetatable getmetatable")))
        add(.init(id: "makefile", label: "Makefile", aliases: ["make", "mk", "gnumake", "mak"], lineComments: ["#"],
                  keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export unexport override vpath"), constants: [], variables: units("$"), targets: true, identifierExtras: units("-./%"), hashNeedsBoundary: true))
        add(.init(id: "markdown", label: "Markdown", aliases: ["md", "mdx", "mkd"], mode: .markdown))
        add(.init(id: "perl", label: "Perl", aliases: ["pl", "pm"], lineComments: ["#"],
                  keywords: words("my our local sub if elsif else unless while until for foreach do last next redo return use require package BEGIN END eq ne lt gt le ge and or not"), constants: [], variables: units("$@%"), hashNeedsBoundary: true))
        add(.init(id: "php", label: "PHP", lineComments: ["//", "#"], blockComments: [["/*", "*/"]],
                  keywords: words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield enum"),
                  constants: ["true", "false", "null", "TRUE", "FALSE", "NULL"], capitalizedTypes: true, variables: units("$"), metaMarkers: ["<?php", "<?=", "?>"]))
        add(.init(id: "powershell", label: "PowerShell", aliases: ["ps1", "pwsh", "ps", "psm1"], lineComments: ["#"], blockComments: [["<#", "#>"]],
                  keywords: words("begin break catch class continue data define do dynamicparam else elseif end exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow"),
                  constants: ["$true", "$false", "$null"], caseInsensitive: true, variables: units("$"), identifierExtras: units("-")))
        add(.init(id: "python", label: "Python", aliases: ["py", "py3", "python3", "gyp", "pyi", "ipython"], lineComments: ["#"], multilineStrings: ["\"\"\"", "'''"],
                  keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda match case nonlocal not or pass raise return try while with yield"),
                  constants: ["True", "False", "None"], builtins: words("print len range enumerate zip map filter sorted reversed list dict set tuple str int float bool bytes open isinstance issubclass super type object min max sum any all abs getattr setattr hasattr"),
                  capitalizedTypes: true, attributes: units("@"), stringPrefixes: units("rRbBuUfF")))
        add(.init(id: "r", label: "R", lineComments: ["#"], keywords: words("if else repeat while function for in next break return switch"),
                  constants: words("TRUE FALSE NULL NA Inf NaN NA_integer_ NA_real_ NA_character_"), builtins: words("c list library require print paste paste0 cat vector matrix"), identifierExtras: units(".")))
        add(.init(id: "ruby", label: "Ruby", aliases: ["rb", "gemfile", "rake", "podfile", "rbs"], lineComments: ["#"], blockComments: [["=begin", "=end"]], strings: ["\"", "'", "`"],
                  keywords: words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return self super then undef unless until when while yield require require_relative attr_accessor attr_reader attr_writer private protected public raise lambda proc puts"),
                  constants: ["true", "false", "nil"], capitalizedTypes: true, variables: units("@$"), symbols: true, identifierExtras: units("?!")))
        add(.init(id: "rust", label: "Rust", aliases: ["rs"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: [], multilineStrings: ["\""],
                  keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type union unsafe use where while"),
                  types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box Rc Arc HashMap"),
                  constants: ["true", "false", "None", "Some", "Ok", "Err"], capitalizedTypes: true, charLiterals: true, rawStrings: true, macros: true, hashAttributes: true))
        add(.init(id: "scala", label: "Scala", aliases: ["sc", "sbt"], lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], multilineStrings: ["\"\"\""],
                  keywords: words("abstract case catch class def do else extends final finally for forSome if implicit import lazy match new object override package private protected return sealed super this throw trait try type val var while with yield given using enum then export extension end derives"),
                  capitalizedTypes: true, attributes: units("@"), charLiterals: true))
        add(.init(id: "sql", label: "SQL", aliases: ["mysql", "postgresql", "postgres", "psql", "pgsql", "sqlite", "plsql", "tsql", "mssql"], lineComments: ["--"], blockComments: [["/*", "*/"]], strings: ["'", "\""],
                  keywords: words("select from where and or not insert into values update set delete create table alter drop index view join inner left right full outer cross on as group by order having limit offset union all distinct case when then else end is in exists between like ilike primary key foreign references constraint default unique check returning with recursive begin commit rollback transaction grant revoke if replace trigger function procedure declare cascade asc desc over partition window materialized database schema column add rename to using natural lateral fetch first next rows only top"),
                  types: words("int integer bigint smallint serial bigserial text varchar char boolean bool date timestamp timestamptz time interval numeric decimal real float double json jsonb uuid blob bytea"),
                  caseInsensitive: true))
        add(.init(id: "svelte", label: "Svelte", mode: .markup))
        add(.init(id: "swift", label: "Swift", lineComments: ["//"], blockComments: [["/*", "*/"]], strings: ["\""], multilineStrings: ["\"\"\""],
                  keywords: words("actor any as associatedtype async await borrowing break case catch class consume consuming continue convenience default defer deinit didSet do dynamic each else enum extension fallthrough fileprivate final for func get guard if import in indirect infix init inout internal is isolated lazy let macro mutating nonisolated nonmutating open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self Self sending set some static struct subscript super switch throw throws try typealias unowned var weak where while willSet"),
                  types: words("Int Int8 Int16 Int32 Int64 UInt UInt8 UInt16 UInt32 UInt64 Double Float CGFloat Bool String Character Array Dictionary Set Optional Result Void Never Any AnyObject Error"),
                  constants: ["true", "false", "nil"], capitalizedTypes: true, attributes: units("@")))
        add(.init(id: "toml", label: "TOML", mode: .ini))
        add(.init(id: "typescript", label: "TypeScript", aliases: ["ts", "mts", "cts"], lineComments: ["//"], blockComments: [["/*", "*/"]], multilineStrings: ["`"], keywords: words(tsKeywords),
                  types: words(tsTypes), constants: ["true", "false", "null", "undefined", "NaN", "Infinity"], capitalizedTypes: true, attributes: units("@"), identifierExtras: units("$")))
        add(.init(id: "tsx", label: "TSX", aliases: ["typescriptreact"], lineComments: ["//"], blockComments: [["/*", "*/"]], multilineStrings: ["`"], keywords: words(tsKeywords),
                  types: words(tsTypes), constants: ["true", "false", "null", "undefined", "NaN", "Infinity"], capitalizedTypes: true, attributes: units("@"), identifierExtras: units("$"), jsxTags: true))
        add(.init(id: "vue", label: "Vue", mode: .markup))
        add(.init(id: "xml", label: "XML", aliases: ["svg", "plist", "xsd", "xsl", "xslt", "rss", "atom", "xaml", "csproj", "storyboard", "xib"], mode: .markup))
        add(.init(id: "yaml", label: "YAML", aliases: ["yml"], lineComments: ["#"], constants: words("true false null yes no on off True False Null TRUE FALSE NULL ~"),
                  variables: units("&*"), keys: true, identifierExtras: units("-."), hashNeedsBoundary: true))
        add(.init(id: "zig", label: "Zig", lineComments: ["//"], strings: ["\""],
                  keywords: words("addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while"),
                  types: words("i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 isize usize f16 f32 f64 f128 bool void anyerror type noreturn comptime_int comptime_float"),
                  constants: ["true", "false", "null", "undefined"], attributes: units("@"), charLiterals: true))
        add(.init(id: "ini", label: "INI", aliases: ["cfg", "conf", "config", "gitignore", "gitattributes", "gitconfig", "editorconfig", "properties", "env", "dotenv", "npmrc"], mode: .ini))
        return list
    }()

    private static let index: [String: CodeLanguage] = {
        var result: [String: CodeLanguage] = [:]
        for language in all { for name in [language.id] + language.aliases where result[name] == nil { result[name] = language } }
        return result
    }()

    /// Resolves a fence language word such as `py`, `c++` or `language-swift`.
    static func language(_ fence: String) -> CodeLanguage? {
        var name = (fence.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "").lowercased()
        if name.hasPrefix("language-") { name.removeFirst("language-".count) }
        if name.hasPrefix(".") { name.removeFirst() }
        if name.hasPrefix("{"), name.hasSuffix("}") { name = String(name.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return index[name]
    }
}
