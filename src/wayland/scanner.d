/+
 +  Copyright © 2015-2016 Rémi Thebault
 +
 +  Permission is hereby granted, free of charge, to any person
 +  obtaining a copy of this software and associated documentation files
 +  (the "Software"), to deal in the Software without restriction,
 +  including without limitation the rights to use, copy, modify, merge,
 +  publish, distribute, sublicense, and/or sell copies of the Software,
 +  and to permit persons to whom the Software is furnished to do so,
 +  subject to the following conditions:
 +
 +  The above copyright notice and this permission notice (including the
 +  next paragraph) shall be included in all copies or substantial
 +  portions of the Software.
 +
 +  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 +  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 +  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 +  NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
 +  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
 +  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
 +  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 +  SOFTWARE.
 +/
/+
 +  A lot of code in this module is inspired by the wayland C scanner
 +/
module wayland.scanner;

import std.stdio;
import std.getopt;
import std.array;

int main(string[] args)
{
    auto opt = new Options;

    opt.cmdline = args.join(" ");

    auto opt_handler = getopt(
            args,
            "input|i", "input file [stdin]", &opt.in_file,
            "output|o", "output file [stdout]", &opt.out_file,
            "module|m", "D module name (required)", &opt.module_name,

            "mode",     "output mode (client or server) [client]", &opt.mode,

            "protocol", "outputs main protocol code", &opt.protocol_code,
            "ifaces", "outputs interfaces code", &opt.ifaces_code,
            "ifaces_priv", "outputs private interface code", &opt.ifaces_priv,
            "ifaces_priv_mod", "specify the private interface module",
                    &opt.ifaces_priv_mod,

            "import|x", "external modules to import", &opt.priv_modules,
            "public|p", "external modules to import publicly", &opt.pub_modules,
        );

    if (opt_handler.helpWanted) {
        defaultGetoptPrinter("A Wayland protocol scanner and D code generator",
                opt_handler.options);
        return 0;
    }

    if ((opt.protocol_code && opt.ifaces_code) ||
            (!opt.protocol_code && !opt.ifaces_code)) {
        stderr.writeln("must specify either procotol or interfaces code");
        return 1;
    }

    if (opt.ifaces_priv && !opt.ifaces_code) {
        stderr.writeln("cannot output priv interface code out of ifaces mode");
        return 1;
    }

    if (opt.ifaces_priv && !opt.ifaces_priv_mod.empty && !opt.module_name.empty) {
        stderr.writeln("interface priv module name must be specified either by -m"
                        ~ " of by --ifaces_priv_mod");
        return 1;
    }

    if (opt.module_name.empty && opt.ifaces_priv && !opt.ifaces_priv_mod.empty) {
        opt.module_name = opt.ifaces_priv_mod;
    }

    if (opt.module_name.empty) {
        stderr.writeln("D module name must be supplied with --module or -m");
        return 1;
    }

    try
    {
        File input = (opt.in_file.empty) ? stdin : File(opt.in_file, "r");
        File output = (opt.out_file.empty) ? stdout : File(opt.out_file, "w");

        string xmlStr;
        foreach (string l; lines(input)) {
            xmlStr ~= l;
        }

        Protocol p;
        {
            auto xmlDoc = new Document;
            xmlDoc.parse(xmlStr, true, true);
            p = Protocol(xmlDoc.root);
        }

        p.printOut(output, opt);
    }
    catch (Exception ex)
    {
        stderr.writeln("Error occured:\n", ex.toString());
        return 1;
    }

    return 0;
}


private:

import arsd.dom;
import std.exception;
import std.uni;
import std.algorithm;
import std.conv;
import std.format;
import std.string;

enum OutputMode
{
    client,
    server,
}

class Options {
    string cmdline;

    string in_file;
    string out_file;
    string module_name;

    OutputMode mode;

    bool protocol_code;
    bool ifaces_code;
    bool ifaces_priv;
    string ifaces_priv_mod;

    string[] priv_modules;
    string[] pub_modules;
}


enum ArgType {
    Int, UInt, Fixed, String, Object, NewId, Array, Fd
}


struct Description {
    string summary;
    string text;

    this (Element parentEl) {
        foreach (el; parentEl.getElementsByTagName("description")) {
            summary = el.getAttribute("summary");
            text = el.getElText();
            break;
        }
    }

    bool opCast(T)() const if (is(T == bool)) {
        return !summary.empty || !text.empty;
    }

    void printOut(File output, int indent=0) {
        string docStr = summary ~ "\n\n" ~ text;
        output.printDocComment(docStr, indent);
    }
}





struct Entry
{
    string iface_name;
    string enum_name;
    string name;
    string value;
    string summary;

    this (Element el, string iface_name, string enum_name) {
        enforce(el.tagName == "entry");
        this.iface_name = iface_name;
        this.enum_name = enum_name;
        name = el.getAttribute("name");
        value = el.getAttribute("value");
        summary = el.getAttribute("summary");
        enforce(!value.empty, "enum entries without value aren't supported");
    }

    @property string d_name() const {
        return iface_name.toUpper ~ '_' ~ enum_name.toUpper ~ '_' ~ name.toUpper;
    }

}

struct Enum
{
    string name;
    string iface_name;
    Description description;
    Entry[] entries;

    this (Element el, string iface_name) {
        enforce(el.tagName == "enum");
        name = el.getAttribute("name");
        this.iface_name = iface_name;
        description = Description(el);
        foreach (entryEl; el.getElementsByTagName("entry")) {
            entries ~= Entry(entryEl, iface_name, name);
        }
    }

    @property d_name() const {
        return iface_name ~ "_" ~ name;
    }

    bool entriesHaveDoc() const {
        return entries.any!(e => !e.summary.empty);
    }

    void printOut(File output, int indent=0)
    {
        if (description)
            description.printOut(output, indent);

        immutable entriesDoc = entriesHaveDoc();
        if (entriesDoc) {
            string docComment;
            foreach(e; entries) {
                if (e.summary.empty)
                    docComment ~= e.d_name ~ '\n';
                else
                    docComment ~= e.d_name ~ ": " ~ e.summary ~ '\n';
            }
            output.printDocComment(docComment, indent);
        }

        bool first=true;
        foreach (e; entries) {
            string eStr = "enum uint " ~ e.d_name ~ " = " ~ e.value ~ ";";
            if (entriesDoc && !first) {
                eStr ~= " /// ditto";
            }
            first = false;
            output.writeln(indentStr(indent), eStr);
        }
    }

}



struct Arg {
    string name;
    string summary;
    string iface;
    ArgType type;

    this (Element el) {
        enforce(el.tagName == "arg");
        name = el.getAttribute("name");
        summary = el.getAttribute("summary");
        iface = el.getAttribute("interface");
        switch (el.getAttribute("type"))
        {
            case "int":
                type = ArgType.Int;
                break;
            case "uint":
                type = ArgType.UInt;
                break;
            case "fixed":
                type = ArgType.Fixed;
                break;
            case "string":
                type = ArgType.String;
                break;
            case "object":
                type = ArgType.Object;
                break;
            case "new_id":
                type = ArgType.NewId;
                break;
            case "array":
                type = ArgType.Array;
                break;
            case "fd":
                type = ArgType.Fd;
                break;
            default:
                enforce(false, "unknown type");
                break;
        }
    }

    @property string d_type() const
    {
        final switch(type) {
            case ArgType.Int:
                return "int ";
            case ArgType.UInt:
                return "uint ";
            case ArgType.Fixed:
                return "wl_fixed_t ";
            case ArgType.String:
                return "const(char) *";
            case ArgType.Object:
                return iface ~ " *";
            case ArgType.NewId:
                return "uint ";
            case ArgType.Array:
                return "wl_array *";
            case ArgType.Fd:
                return "int ";
        }
    }

    @property string d_name() const {
        if (name == "interface") {
            return "iface";
        }
        else if (name == "version") {
            return "ver";
        }
        return name;
    }

}


struct Message
{
    string name;
    string iface_name;
    int since = 1;
    bool is_dtor;
    Description description;
    Arg[] args;

    this (Element el, string iface_name) {
        enforce(el.tagName == "request" || el.tagName == "event");
        name = el.getAttribute("name");
        this.iface_name = iface_name;
        if (el.hasAttribute("since")) {
            since = el.getAttribute("since").to!int;
        }
        is_dtor = (el.getAttribute("type") == "destructor");
        description = Description(el);
        foreach (argEl; el.getElementsByTagName("arg")) {
            args ~= Arg(argEl);
        }
    }

    @property string opCodeSym() const {
        return iface_name.toUpper ~ "_" ~ name.toUpper;
    }


    void printCallbackOut(File output, int indent, bool server)
    {
        if (description)
            description.printOut(output, indent);

        string code = "void function (";
        string argIndent = array(" ".replicate(code.length)).to!string;

        if (server) {
            code ~= "wl_client *client,\n";
            code ~= argIndent ~ "wl_resource *resource";
        }
        else {
            code ~= "void *data,\n";
            code ~= argIndent ~ format("%s *%s", iface_name, iface_name);
        }

        foreach(arg; args) {
            code ~= ",\n" ~ argIndent;

            if (server && arg.type == ArgType.Object)
                code ~= "wl_resource *";
            else if (server && arg.type == ArgType.NewId && arg.iface.empty)
                code ~= "const(char) *iface, uint ver, uint ";
            else if (!server && arg.type == ArgType.Object && arg.iface.empty)
                code ~= "void *";
            else if (!server && arg.type == ArgType.NewId)
                code ~= arg.iface ~ " *";
            else
                code ~= arg.d_type;

            code ~= arg.d_name;
        }

        code ~= format(") %s;", name);

        output.printCode(code, indent);
    }


    void printStubOut(File output, int indent)
    {
        Arg *ret;
        foreach (i; 0..args.length) {
            if (args[i].type == ArgType.NewId) {
                if (ret) {
                    stderr.writefln(
                        "message '%s.%s' has more than one new_id arg\n" ~
                        "not emitting stub", iface_name, name);
                    return;
                }
                ret = &args[i];
            }
        }

        foreach(arg; args) {
            enforce (!arg.iface.empty || arg.type != ArgType.Object,
                format("%s is object and has no interface defined", arg.name));
        }

        string rettype = "void";
        if (ret) {
            if (ret.iface.empty) {
                rettype = "void *";
            }
            else {
                rettype = format("%s *", ret.iface);
            }
        }

        string code = format(
                "extern (D) %s\n" ~
                "%s_%s(%s *%s_", rettype, iface_name, name,
                iface_name, iface_name);
        foreach (arg; args) {
            if (arg.type == ArgType.NewId) {
                if (arg.iface.empty)
                    code ~= ", const(wl_interface) *iface, uint ver";
            }
            else {
                code ~= format(", %s%s", arg.d_type, arg.d_name);
            }
        }

        code ~= ")\n{\n";

        if (ret) {
            code ~= format("    wl_proxy *%s;\n\n", ret.d_name);
            code ~= format("    %s = wl_proxy_marshal_constructor(\n", ret.d_name);
            code ~= format("            cast(wl_proxy*) %s_,\n", iface_name);
            code ~= format("            %s, ", opCodeSym);
            if (ret.iface.empty)
                code ~= "iface";
            else
                code ~= format("%s_interface", ret.iface);
        }
        else {
            code ~= format("    wl_proxy_marshal(cast(wl_proxy*) %s_,\n", iface_name);
            code ~= format("            %s", opCodeSym);
        }

        foreach (arg; args) {
            if (arg.type == ArgType.NewId) {
                if (arg.iface.empty) {
                    code ~= ", iface.name, ver";
                }
                code ~= ", null";
            }
            else {
                code ~= format(", %s", arg.d_name);
            }
        }
        code ~= ");\n";

        if (is_dtor) {
            code ~= format("\n    wl_proxy_destroy(cast(wl_proxy*) %s_);\n", iface_name);
        }

        if (ret) {
            if (ret.iface.empty)
                code ~= format("\n    return cast(void *) %s;\n", ret.d_name);
            else
                code ~= format("\n    return cast(%s *) %s;\n",
                                ret.iface, ret.d_name);
        }

        code ~= "}";

        if (description)
            description.printOut(output, indent);
        output.printCode(code, indent);
    }


    void printEventWrapperOut(File output, int indent)
    {
        string code = format(
                "extern (D) void\n" ~
                "%s_send_%s(wl_resource *res", iface_name, name);

        foreach (arg; args) {
            code ~= ", ";
            switch(arg.type) {
            case ArgType.NewId:
            case ArgType.Object:
                code ~= "wl_resource *";
                break;
            default:
                code ~= arg.d_type;
                break;
            }
            code ~= arg.d_name;
        }

        code ~= format(")\n"    ~
            "{\n"               ~
            "    wl_resource_post_event(res, %s", opCodeSym);
        foreach (arg; args) {
            code ~= format(", %s", arg.d_name);
        }
        code ~= ");\n}";

        if (description) description.printOut(output, indent);
        output.printCode(code, indent);
    }

}


struct Interface
{
    string name;
    string ver;
    Description description;
    Message[] requests;
    Message[] events;
    Enum[] enums;

    this (Element el) {
        enforce(el.tagName == "interface");
        name = el.getAttribute("name");
        ver = el.getAttribute("version");
        description = Description(el);
        foreach (rqEl; el.getElementsByTagName("request")) {
            requests ~= Message(rqEl, name);
        }
        foreach (evEl; el.getElementsByTagName("event")) {
            events ~= Message(evEl, name);
        }
        foreach (enEl; el.getElementsByTagName("enum")) {
            enums ~= Enum(enEl, name);
        }
    }


    @property bool haveListener() const {
        return !events.empty;
    }

    @property bool haveInterface() const {
        return !requests.empty;
    }

    void printOutEnumCode(File output, int indent)
    {
        foreach (e; enums) {
            e.printOut(output, indent);
            output.writeln();
        }
    }


    void printOutClientCode(File output, int indent)
    {
        if (haveListener) {
            // listener struct
            if (description) description.printOut(output, indent);
            output.printCode(format("struct %s_listener\n{", name), indent);
            foreach (ev; events) {
                ev.printCallbackOut(output, indent+1, false);
            }
            output.printCode("}", indent);
            output.writeln();

            // add listener method
            output.printCode(format(
                "extern (D) int\n"                                              ~
                "%s_add_listener(%s *%s,\n"                                     ~
                "                const(%s_listener) *listener, void *data)\n"   ~
                "{\n"                                                           ~
                "    alias Callback = extern (C) void function();\n\n"          ~
                "    return wl_proxy_add_listener(\n"                           ~
                "            cast(wl_proxy*)%s,\n"                              ~
                "            cast(Callback*)listener, data);\n"                 ~
                "}",
                name, name, name, name, name), indent);
            output.writeln();
        }

        // opcodes
        foreach (i, rq; requests) {
            output.printCode(format("enum uint %s = %s;",
                                rq.opCodeSym, i),
                                indent);
        }
        output.writeln();

        // write user data getter and setter
        output.printCode(format(
            "extern (D) void\n"                                             ~
            "%s_set_user_data(%s *%s, void *user_data)\n"                   ~
            "{\n"                                                           ~
            "    wl_proxy_set_user_data(cast(wl_proxy*) %s, user_data);\n"  ~
            "}", name, name, name, name), indent);
        output.writeln();
        output.printCode(format(
            "extern (D) void *\n"                                       ~
            "%s_get_user_data(%s *%s)\n"                                ~
            "{\n"                                                       ~
            "    return wl_proxy_get_user_data(cast(wl_proxy*) %s);\n"  ~
            "}", name, name, name, name), indent);
        output.writeln();

        bool hasDtor=false;
        bool hasDestroy=false;
        foreach (rq; requests) {
            if (rq.is_dtor) hasDtor = true;
            if (rq.name == "destroy") hasDestroy = true;
        }
        enforce(hasDtor || !hasDestroy);

        if (!hasDestroy && name != "wl_display") {
            output.printCode(format(
                "extern (D) void\n"                             ~
                "%s_destroy(%s *%s)\n"                          ~
                "{\n"                                           ~
                "    wl_proxy_destroy(cast(wl_proxy*) %s);\n"   ~
                "}", name, name, name, name), indent);
            output.writeln();
        }

        foreach(rq; requests) {
            rq.printStubOut(output, indent);
            output.writeln();
        }
    }


    void printOutServerCode(File output, int indent)
    {
        if (haveInterface) {
            // interface struct
            if (description) description.printOut(output, indent);
            output.printCode(format("struct %s_interface\n{", name), indent);
            foreach (rq; requests) {
                rq.printCallbackOut(output, indent+1, true);
            }
            output.printCode("}", indent);
            output.writeln();
        }

        // opcodes
        foreach (i, ev; events) {
            output.printCode(format("enum uint %s = %s;",
                                ev.opCodeSym, i),
                                indent);
        }
        output.writeln();

        // versions
        foreach (i, ev; events) {
            output.printCode(format("enum uint %s_SINCE_VERSION = %s;",
                                ev.opCodeSym, ev.since),
                                indent);
        }
        output.writeln();

        if (name != "wl_display") {
            // wl_display have hand coded functions
            foreach (ev; events) {
                ev.printEventWrapperOut(output, indent);
                output.writeln();
            }
        }

    }


    void printProtocolOut(File output, Options opt, int indent=0)
    {
        printOutEnumCode(output, indent);

        final switch (opt.mode)
        {
            case OutputMode.client:
                printOutClientCode(output, indent);
                break;
            case OutputMode.server:
                printOutServerCode(output, indent);
                break;
        }
    }

}


struct Protocol
{
    string name;
    string copyright;
    Interface[] ifaces;

    this(Element el) {
        enforce(el.tagName == "protocol");
        name = el.getAttribute("name");
        foreach (cr; el.getElementsByTagName("copyright")) {
            copyright = cr.getElText();
            break;
        }
        foreach (ifEl; el.getElementsByTagName("interface")) {
            ifaces ~= Interface(ifEl);
        }
    }

    Enum[] getEnums() {
        Enum[] enums;
        foreach (iface; ifaces) {
            enums ~= iface.enums;
        }
        return enums;
    }


    void printLoaderOut(File output, Options opt, int indent)
    {
        string mode = (opt.mode == OutputMode.server) ? "Server" : "Client";

        string code = "import derelict.util.loader;\n\n";

        code ~= format("class %s%sLoader : SharedLibLoader {\n",
            name.capitalize, mode);

        code ~=
            "    this (string libName) {\n" ~
            "        super(libName);\n"     ~
            "    }\n";

        code ~= "    protected override void loadSymbols() {\n";
        foreach(iface; ifaces) {
            code ~= "        " ~ format(
                "%s_if_ptr = cast(wl_interface*) loadSymbol(\"%s_interface\");\n",
                iface.name, iface.name);
        }
        code ~= "    }\n";
        code ~= "}";

        output.printCode(code, indent);
    }


    void printOut(File output, Options opt) {
        if (!copyright.empty) {
            output.printComment("Protocol copyright:\n"~copyright);
        }
        output.printComment(
                "D bindings copyright:\n"       ~
                "Copyright © 2015 Rémi Thebault");
        output.printComment(
                "    File generated by wayland-scanner-d:\n" ~
                opt.cmdline ~ "\n    Do not edit!");

        output.writeln("module ", opt.module_name, ";\n");

        string mode = (opt.mode == OutputMode.server) ? "server" : "client";

        output.writeln(format("import wayland.%s.util;", mode));
        output.writeln(format("import wayland.%s.opaque_types;", mode));
        foreach (mod; opt.priv_modules)
            output.writeln("import ", mod, ";");
        foreach (mod; opt.pub_modules)
            output.writeln("public import ", mod, ";");
        output.writeln();

        if (opt.protocol_code) {
            output.writeln("extern (C) {\n");

            foreach (iface; ifaces) {
                if (iface.name == "wl_display") continue;
                output.printCode(format("struct %s;", iface.name), 1);
            }
            output.writeln();

            foreach (iface; ifaces)
            {
                iface.printProtocolOut(output, opt, 1);
            }

            output.writeln("\n} // extern (C)\n");
        }

        if (opt.ifaces_code) {
            if (opt.ifaces_priv) {
                output.writeln("extern (C) {\n");

                output.printCode("version (Dynamic) {}", 1);
                output.printCode("else {", 1);
                foreach (iface; ifaces) {
                    output.printCode(format(
                        "extern __gshared wl_interface %s_interface;",
                        iface.name), 2);
                }
                output.printCode("}", 1);

                output.writeln("\n} // extern (C)\n");
            }
            else {
                output.writeln("version (Dynamic) {\n");
                output.printCode("private {", 1);
                foreach(iface; ifaces) {
                    output.printCode(format(
                        "__gshared wl_interface *%s_if_ptr;",
                        iface.name), 2);
                }
                output.printCode("}", 1);
                output.writeln();

                output.printCode("package {", 1);
                printLoaderOut(output, opt, 2);

                output.printCode("}", 1);
                output.writeln();

                foreach (iface; ifaces) {
                    string code = format(
                        "@property wl_interface *%s_interface() {\n"    ~
                        "    return %s_if_ptr;\n"                       ~
                        "}", iface.name, iface.name);
                    output.printCode(code, 1);
                }

                output.printCode("\n}\nelse {\n", 0);

                output.printCode(format(
                        "import priv = %s;",
                        opt.ifaces_priv_mod), 1);
                output.writeln();

                foreach (iface; ifaces) {
                    string code = format(
                        "@property wl_interface *%s_interface() {\n"    ~
                        "    return &priv.%s_interface;\n"              ~
                        "}", iface.name, iface.name);
                    output.printCode(code, 1);
                }

                output.printCode("\n}", 0);
            }
        }
    }
}


string getElText(Element el)
{
    string fulltxt;
    foreach (child; el.children) {
        if (child.nodeType == NodeType.Text) {
            fulltxt ~= child.nodeValue;
        }
    }

    string[] lines;
    string offset;
    bool offsetdone = false;
    foreach (l; fulltxt.split('\n')) {
        immutable bool allwhite = l.all!isWhite;
        if (!offsetdone && allwhite) continue;

        if (!offsetdone && !allwhite) {
            offsetdone = true;
            offset = l
                    .until!(c => !c.isWhite)
                    .to!string;
        }

        if (l.startsWith(offset)) {
            l = l[offset.length .. $];
        }

        lines ~= l;
    }

    foreach_reverse(l; lines) {
        if (l.all!isWhite) {
            lines = lines[0..$-1];
        }
        else break;
    }

    return lines.join("\n");
}


void printComment(File output, string text, int indent=0)
{
    auto indStr = indentStr(indent);
    output.writeln(indStr, "/+");
    foreach (l; text.split("\n")) {
        if (l.empty) output.writeln(indStr, " +");
        else output.writeln(indStr, " +  ", l);
    }
    output.writeln(indStr, " +/");
}


void printDocComment(File output, string text, int indent=0)
{
    auto indStr = indentStr(indent);
    output.writeln(indStr, "/++");
    foreach (l; text.split("\n")) {
        if (l.empty) output.writeln(indStr, " +");
        else output.writeln(indStr, " +  ", l);
    }
    output.writeln(indStr, " +/");
}


/++
 + prints indented code and adds a final '\n'
 +/
void printCode(File output, string code, int indent=0)
{
    auto iStr = indentStr(indent);
    foreach (l; code.split("\n")) {
        if (l.empty) output.writeln();
        else output.writeln(iStr, l);
    }
}


string indentStr(int indent)
{
    return "    ".replicate(indent);
}
