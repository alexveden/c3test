module c3tools::ast;
import c3tools::lexer;
import std::io;
import std::collections::list;

struct AstProject {
    String proj_path;
    String stdlib_path;
    List(<AstModule*>) modules;
    allocator::DynamicArenaAllocator _allocator;
}

struct Ast {
    String path;
    AstModule* modules;
    allocator::DynamicArenaAllocator* _allocator;
    Lexer lexer;
    List(<NodeParserState>) state_stack;
}

def NodeParser = fn bool (Ast* ast, AstNode* node, Token* t, NodeParserState* state);

struct NodeParserState {
    TokenType current_state;
    TokenType last_state;
    AstNode* sub_node;
    uint scope_depth;
    TokenType[32] scope_stack;
}

struct AstNode {
    TokenType type;
    uint istart;
    uint iend;
    AstNode* next;
    String value;
}

struct AstModule {
    inline AstNode node;
    AstNode* name;
    AstNode* attributes;
    AstImport* imports;
    AstNode* decls;
    AstDoc* docs;
    String file_path;
}

struct AstTypeDef {
    inline AstNode node;
    AstNode* field;
    AstNode* attributes;
    AstDoc* docs;
}
struct AstTypeDefEnumerable {
    inline AstTypeDef node;
    AstNode* values;
}
struct AstTypeDefInterface {
    inline AstTypeDef node;
    AstCallable* functions;
}
struct AstTypeDefStructural {
    inline AstTypeDef node;
    AstTypeDef* inlines;
    AstTypeDef* members;
}

struct AstCallable {
    inline AstNode node;
    AstNode* name;
    AstNode* ret_type;
    AstCallableParam* params;
    AstNode* attributes;
    AstDoc* docs;
    uint iscope_start;
}
struct AstCallableParam {
    inline AstNode node;
    AstNode* param_type;
    AstNode* attributes;
}

struct AstImport {
    inline AstNode node;
    AstNode* name;
    AstNode* attributes;
}

struct AstDoc {
    inline AstNode node;
    AstDocContract* contracts;
}

struct AstDocContract {
    inline AstNode node;
    AstNode* items;
}


//
//                 NODE MANAGEMENT
//

macro @node_last(self) @private 
{
    assert(self != null);
    $typeof(self) node = self;
    while(node.next) {
        node = ($typeof(self))node.next;            
    }
    return node;
}

macro AstNode* @node_add(AstNode** self, AstNode* new) @private 
{
    assert(self != null);

    if (*self == null) {
        ((AstNode*)*self) = new;
    } else {
        AstNode* node = @node_last(*self);
        node.next = new;
    }
    return new;
}

macro @node_foreach(#self; @body(item))
{
    var node = #self;
    while(node) {
        @body(node);
        node = ($typeof(#self))node.next;            
    }
}

macro Ast.@allc_add(&self, $Type, AstNode** collection, lexer::Token* token) @private {
    $Type* result = self._allocator.acquire($Type.sizeof, NO_ZERO, $Type.alignof)!!;
    *result = {
        .type = token.type,
        .istart = token.offset,
        .iend = token.offset + token.value.len,
        .value = self.@allc_str(token.value),
    };
    return @node_add(collection,  result);
}

macro Ast.@node_join(self, node, DString out_str, String sep = ",")
{
    out_str.clear();
    $typeof(node) _node = node;
    while(_node) {
        out_str.append(_node.value);
        _node = ($typeof(node))_node.next;            
        if (_node) {
            out_str.append(sep);
        }
    }
    return out_str.str_view();
}
macro uint Ast.@node_len(self, node)
{
    uint len = 0;
    $typeof(node) _node = node;
    while(_node) {
        len++;
        _node = ($typeof(node))_node.next;            
    }
    return len;
}
macro Ast.@node_at(self, node, uint index)
{
    uint len = 0;
    $typeof(node) _node = node;
    while(_node) {
        if(len == index) return _node;
        len++;
        _node = ($typeof(node))_node.next;            
    }
    return _node;
}

macro String Ast.@allc_str(&self, String s) @private {
    String result = s.copy(self._allocator);
    return result;
}


fn Ast parse(String contents, String file_path, bool print_lex = false, DynamicArenaAllocator* allc = null) {
    Ast self;
    if (allc == null){
        // typically this will be actual only for tests
        self._allocator = mem::alloc(DynamicArenaAllocator);
        self._allocator.init(1024, allocator::temp());
    } else {
        self._allocator = allc;
    }
    self.path = self.@allc_str(file_path);

	lexer::init(&self.lexer, contents);
	NodeParser node_fn = null;
	AstNode* node = null;
	AstDoc* docstring = null;
	AstModule* current_module = (AstModule*)self.@allc_add(AstModule, &self.modules, &self.lexer.token);
	current_module.file_path = self.path;

	self.state_stack.new_init();
	defer self.state_stack.free();

	while LOOP: (self.lexer.next_token()) {
	    if (print_lex) self.lexer.token.print();

		if (!node_fn) {
		    switch(self.lexer.token.type) {
                case MODULE:
                    node_fn = &Ast.parse_module;
                    if (self.modules.next == null) {
                        // first `module` keyword, check if there is no decls/imports in default
                        // and remove it from modules list if it's completely empty
                        if(!self.modules.decls && !self.modules.imports){
                            assert(!self.modules.name);
                            self.modules = null;
                        }
                    }
                    node = self.@allc_add(AstModule, &self.modules, &self.lexer.token); 
                    current_module = (AstModule*)node;
                    current_module.docs = docstring;
	                current_module.file_path = self.path;
                case MACRO:
                case FN:
                    node_fn = &Ast.parse_function;
                    node = self.@allc_add(AstCallable, &current_module.decls, &self.lexer.token); 
                    ((AstCallable*)node).docs = docstring;
                case IMPORT:
                    node_fn = &Ast.parse_import;
                    node = self.@allc_add(AstImport, &current_module.imports, &self.lexer.token); 
                case DOCS_START:
                    // Global doc strings
                    docstring = null; // reset all previous docs
                    node_fn = &Ast.parse_docstring;
                    node = self.@allc_add(AstDoc, &docstring, &self.lexer.token); 
                case ENUM:
                case FAULT:
                    node_fn = &Ast.parse_enumerable;
                    node = self.@allc_add(AstTypeDefEnumerable, &current_module.decls, &self.lexer.token); 
                    ((AstTypeDefEnumerable*)node).docs = docstring;
                case INTERFACE:
                    node_fn = &Ast.parse_interface;
                    node = self.@allc_add(AstTypeDefInterface, &current_module.decls, &self.lexer.token); 
                    ((AstTypeDefInterface*)node).docs = docstring;
                case STRUCT:
                case UNION:
                case BITSTRUCT:
                    node_fn = &Ast.parse_structural;
                    node = self.@allc_add(AstTypeDefStructural, &current_module.decls, &self.lexer.token); 
                    ((AstTypeDefStructural*)node).docs = docstring;
                case DEF:
                case DISTINCT:
                    node_fn = &Ast.parse_typedef;
                    node = self.@allc_add(AstTypeDef, &current_module.decls, &self.lexer.token); 
                    ((AstTypeDef*)node).docs = docstring;
                case CONST:
                    node_fn = &Ast.parse_constants;
                    node = self.@allc_add(AstTypeDef, &current_module.decls, &self.lexer.token); 
                    ((AstTypeDef*)node).docs = docstring;
                default:
                    continue LOOP;
		    }

		    assert(self.state_stack.len() == 0);
		    self.state_stack.push(NodeParserState{});
		}

		if(node_fn(&self, node, &self.lexer.token, &self.state_stack[0])) {
		    // Node was finished, scan next;
		    if(node.type != DOCS_START) docstring = null;
		    node_fn = null;
		    node = null;
		    assert(self.state_stack.len() == 0, "not cleared?");
		}
	}

    if (self.modules) {
        AstModule* last_mod = @node_last(self.modules); 
        last_mod.iend = self.lexer.token.offset - 1;
    }
    self.state_stack.clear();

	return self;
}

fn AstProject AstProject.new_init(String proj_path, String stdlib_path) @operator(construct) {
    AstProject self = {
        .proj_path = proj_path,
        .stdlib_path = stdlib_path,
    };

    //  Arena allocator for storing all AST metadata (DynamicArenaAllocator backed by heap)
    self._allocator.init(5*1024*1024, allocator::heap());

    // All other allocations are done on heap to isolate AST data and make it sequential
    self.modules.new_init(initial_capacity: 1024, allocator: allocator::heap());

    return self;
}

fn void! AstProject.load(&self) {
    if (self.proj_path) {
        path::Path p = path::temp_new(self.proj_path)!;
        if (!path::is_dir(p)) {
            return IoError.FILE_NOT_DIR?;
        }

        path::PathWalker fnwalk = fn bool!(Path p, bool is_dir, void* ctx) {
            AstProject* self = (AstProject*)ctx;
            if (is_dir) return false;

	        String contents = (String)file::load_new(p.str_view())!;
	        defer contents.free();

            Ast ast = ast::parse(contents, file_path: p.str_view(), allc: &self._allocator);
            self.import_ast(&ast)!;

            return false;
        };
        p.walk(fnwalk, self)!!;
    }
}

fn void! AstProject.import_ast(&self, Ast* ast) {
    assert(ast);

    for(AstModule* m = ast.modules; m != null; m = (AstModule*)m.next) {
        io::printfn("%s: module: %s", ast.path, m);
        self.modules.push(m);
    }
    return;
}

fn void AstProject.free(&self) {
    self.modules.free();
    self._allocator.free();
}
