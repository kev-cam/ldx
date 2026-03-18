#!/usr/bin/env python3
"""
c2v.py — C function to synthesizable Verilog.

Parses a C function's AST, walks backward from return to inputs,
and emits combinational Verilog. if/else becomes MUX. Loops must
be bounded (unrolled). No pointers, no malloc, no I/O.

Usage:
    python3 c2v.py input.c -f function_name -o output.v

The output is a Verilog module with:
- Input ports for each function parameter
- Output port for the return value
- Combinational logic (assign / always @(*))
- Optional AXI-Lite wrapper (--axi)
"""

import clang.cindex
import sys
import os
import argparse
from dataclasses import dataclass, field
from typing import List, Dict, Optional, Tuple

# Configure libclang
LIBCLANG_PATHS = [
    '/usr/lib/x86_64-linux-gnu/libclang-14.so.1',
    '/usr/lib/x86_64-linux-gnu/libclang-14.so',
    '/usr/lib/llvm-14/lib/libclang.so',
    '/usr/lib/libclang.so',
]

for p in LIBCLANG_PATHS:
    if os.path.exists(p):
        clang.cindex.Config.set_library_file(p)
        break

CursorKind = clang.cindex.CursorKind

# ---- Verilog AST nodes ----

@dataclass
class VNode:
    """A node in the Verilog expression tree."""
    pass

@dataclass
class VInput(VNode):
    name: str
    width: int  # bits

@dataclass
class VConst(VNode):
    value: int
    width: int

@dataclass
class VBinOp(VNode):
    op: str  # +, -, *, /, &, |, ^, <<, >>, <, >, ==, !=, <=, >=
    left: VNode
    right: VNode
    width: int

@dataclass
class VUnaryOp(VNode):
    op: str  # ~, !, -
    operand: VNode
    width: int

@dataclass
class VMux(VNode):
    """if/else → MUX: sel ? a : b"""
    sel: VNode
    true_val: VNode
    false_val: VNode
    width: int

@dataclass
class VCast(VNode):
    operand: VNode
    width: int

@dataclass
class VWire(VNode):
    """Named intermediate wire (for local variables)."""
    name: str
    expr: VNode
    width: int


# ---- C type → Verilog width ----

TYPE_WIDTHS = {
    'int': 32, 'unsigned int': 32, 'uint32_t': 32, 'int32_t': 32,
    'short': 16, 'unsigned short': 16, 'uint16_t': 16, 'int16_t': 16,
    'char': 8, 'unsigned char': 8, 'uint8_t': 8, 'int8_t': 8,
    'long': 64, 'unsigned long': 64, 'uint64_t': 64, 'int64_t': 64,
    'long long': 64, 'unsigned long long': 64,
    'float': 32, 'double': 64,
    '_Bool': 1, 'bool': 1,
}

def type_width(type_spelling: str) -> int:
    """Get bit width from C type name."""
    t = type_spelling.strip()
    if t in TYPE_WIDTHS:
        return TYPE_WIDTHS[t]
    # Strip qualifiers
    for q in ('const ', 'volatile ', 'restrict '):
        t = t.replace(q, '')
    if t in TYPE_WIDTHS:
        return TYPE_WIDTHS[t]
    return 32  # default

def is_signed(type_spelling: str) -> bool:
    t = type_spelling.strip().replace('const ', '')
    return not ('unsigned' in t or t.startswith('uint'))

def is_floating(type_spelling: str) -> bool:
    t = type_spelling.strip()
    return t in ('float', 'double')


# ---- C AST → Verilog tree ----

C_TO_V_OPS = {
    '+': '+', '-': '-', '*': '*', '/': '/',
    '%': '%', '&': '&', '|': '|', '^': '^',
    '<<': '<<', '>>': '>>',
    '<': '<', '>': '>', '<=': '<=', '>=': '>=',
    '==': '==', '!=': '!=',
    '&&': '&&', '||': '||',
}

def get_binary_op(cursor) -> Optional[str]:
    """Extract the operator from a BINARY_OPERATOR cursor.
    Clang doesn't expose this directly, so we find the token between
    the end of the left child and start of the right child."""
    children = list(cursor.get_children())
    if len(children) != 2:
        return None

    # Get the source range boundary between the two children
    left_end = children[0].extent.end
    right_start = children[1].extent.start

    ops = set(C_TO_V_OPS.keys())
    tokens = list(cursor.get_tokens())
    for tok in tokens:
        # Token must be after left child and before right child
        if (tok.location.offset >= left_end.offset and
            tok.location.offset < right_start.offset and
            tok.spelling in ops):
            return tok.spelling

    # Fallback: compound assignment
    for tok in tokens:
        if (tok.location.offset >= left_end.offset and
            tok.location.offset < right_start.offset and
            tok.spelling in ('+=', '-=', '*=', '/=', '&=', '|=', '^=', '<<=', '>>=')):
            return tok.spelling[:-1]
    return None

def get_unary_op(cursor) -> Optional[str]:
    tokens = list(cursor.get_tokens())
    for tok in tokens:
        if tok.spelling in ('~', '!', '-', '+'):
            return tok.spelling
    return None


class C2VConverter:
    """Convert a C function's AST to a Verilog expression tree."""

    def __init__(self):
        self.params: Dict[str, Tuple[int, bool]] = {}  # name → (width, signed)
        self.locals: Dict[str, VNode] = {}  # name → expression
        self.wires: List[VWire] = []
        self.wire_counter = 0
        self.warnings: List[str] = []

    def convert_function(self, cursor) -> Tuple[List[Tuple[str, int, bool]], VNode, int]:
        """Convert a function cursor to (params, return_expr, return_width)."""
        params = []
        body = None
        ret_width = type_width(cursor.result_type.spelling)

        for child in cursor.get_children():
            if child.kind == CursorKind.PARM_DECL:
                w = type_width(child.type.spelling)
                s = is_signed(child.type.spelling)
                self.params[child.spelling] = (w, s)
                params.append((child.spelling, w, s))
            elif child.kind == CursorKind.COMPOUND_STMT:
                body = child

        if not body:
            raise ValueError("No function body found")

        # Walk the body, collect local variable assignments, find return
        return_expr = self._walk_body(body)

        if return_expr is None:
            raise ValueError("No return statement found")

        return params, return_expr, ret_width

    def _walk_body(self, compound) -> Optional[VNode]:
        """Walk compound statement, return the VNode for the return value."""
        return_expr = None

        for stmt in compound.get_children():
            if stmt.kind == CursorKind.RETURN_STMT:
                children = list(stmt.get_children())
                if children:
                    return_expr = self._expr(children[0])
            elif stmt.kind == CursorKind.DECL_STMT:
                # Local variable declaration
                for decl in stmt.get_children():
                    if decl.kind == CursorKind.VAR_DECL:
                        name = decl.spelling
                        w = type_width(decl.type.spelling)
                        children = list(decl.get_children())
                        if children:
                            expr = self._expr(children[-1])
                            self.locals[name] = expr
                            self.wires.append(VWire(name, expr, w))
            elif stmt.kind == CursorKind.BINARY_OPERATOR and self._is_assignment(stmt):
                # x = expr  (plain assignment to local or parameter)
                children = list(stmt.get_children())
                if len(children) == 2:
                    target_name = children[0].spelling
                    rhs = self._expr(children[1])
                    w = type_width(stmt.type.spelling)
                    self.wire_counter += 1
                    wire_name = f"{target_name}_{self.wire_counter}"
                    self.locals[target_name] = rhs
                    self.wires.append(VWire(wire_name, rhs, w))
            elif stmt.kind == CursorKind.COMPOUND_ASSIGNMENT_OPERATOR:
                # r |= b  →  r = r_old | b
                children = list(stmt.get_children())
                if len(children) == 2:
                    target_name = children[0].spelling
                    rhs = self._expr(children[1])
                    # Extract operator from tokens (|=, &=, ^=, +=, -=, <<=, >>=)
                    tokens = list(stmt.get_tokens())
                    op = None
                    for tok in tokens:
                        if tok.spelling.endswith('=') and len(tok.spelling) >= 2 and tok.spelling != '==':
                            op = tok.spelling[:-1]  # |= → |, ^= → ^
                            break
                    if op and op in C_TO_V_OPS and target_name in self.locals:
                        old_val = self.locals[target_name]
                        w = type_width(stmt.type.spelling)
                        new_expr = VBinOp(C_TO_V_OPS[op], old_val, rhs, w)
                        # Update the local to the new chained expression
                        self.wire_counter += 1
                        wire_name = f"{target_name}_{self.wire_counter}"
                        self.locals[target_name] = new_expr
                        self.wires.append(VWire(wire_name, new_expr, w))
                    elif op and target_name in self.params:
                        # Parameter used as mutable local (e.g. parity modifies x)
                        w, s = self.params[target_name]
                        old_val = self.locals.get(target_name, VInput(target_name, w))
                        new_expr = VBinOp(C_TO_V_OPS.get(op, op), old_val, rhs, w)
                        self.wire_counter += 1
                        wire_name = f"{target_name}_{self.wire_counter}"
                        self.locals[target_name] = new_expr
                        self.wires.append(VWire(wire_name, new_expr, w))
            elif stmt.kind == CursorKind.COMPOUND_STMT:
                r = self._walk_body(stmt)
                if r:
                    return_expr = r
            elif stmt.kind == CursorKind.IF_STMT:
                return_expr = self._handle_if(stmt)
            elif stmt.kind == CursorKind.FOR_STMT:
                self.warnings.append("for loop found — must be unrollable for combinational Verilog")
                return_expr = self._handle_for(stmt)

        return return_expr

    def _is_assignment(self, cursor) -> bool:
        """Check if a BINARY_OPERATOR is a plain assignment (=)."""
        children = list(cursor.get_children())
        if len(children) != 2:
            return False
        # Check if the left side is a DECL_REF_EXPR to a known local/param
        left = children[0]
        while left.kind == CursorKind.UNEXPOSED_EXPR:
            c = list(left.get_children())
            if c:
                left = c[0]
            else:
                break
        if left.kind != CursorKind.DECL_REF_EXPR:
            return False
        name = left.spelling
        if name not in self.locals and name not in self.params:
            return False
        # Check tokens for '=' but not '==', '!=', '<=', '>='
        tokens = list(cursor.get_tokens())
        left_end = children[0].extent.end
        right_start = children[1].extent.start
        for tok in tokens:
            if (tok.location.offset >= left_end.offset and
                tok.location.offset < right_start.offset):
                if tok.spelling == '=':
                    return True
        return False

    def _expr(self, cursor) -> VNode:
        """Convert a C expression cursor to a VNode."""
        kind = cursor.kind

        if kind == CursorKind.INTEGER_LITERAL:
            tokens = list(cursor.get_tokens())
            val = int(tokens[0].spelling, 0) if tokens else 0
            return VConst(val, type_width(cursor.type.spelling))

        if kind == CursorKind.FLOATING_LITERAL:
            # For now, represent as integer bits
            tokens = list(cursor.get_tokens())
            self.warnings.append(f"floating literal {tokens[0].spelling if tokens else '?'} — needs FP support")
            return VConst(0, type_width(cursor.type.spelling))

        if kind == CursorKind.DECL_REF_EXPR:
            name = cursor.spelling
            if name in self.locals:
                return self.locals[name]
            if name in self.params:
                w, _ = self.params[name]
                return VInput(name, w)
            self.warnings.append(f"unknown reference: {name}")
            return VInput(name, 32)

        if kind == CursorKind.BINARY_OPERATOR:
            children = list(cursor.get_children())
            if len(children) == 2:
                op = get_binary_op(cursor)
                left = self._expr(children[0])
                right = self._expr(children[1])
                w = type_width(cursor.type.spelling)
                if op and op in C_TO_V_OPS:
                    return VBinOp(C_TO_V_OPS[op], left, right, w)
            self.warnings.append(f"unhandled binary operator at {cursor.location}")
            return VConst(0, 32)

        if kind == CursorKind.UNARY_OPERATOR:
            children = list(cursor.get_children())
            if children:
                op = get_unary_op(cursor)
                operand = self._expr(children[0])
                w = type_width(cursor.type.spelling)
                if op == '~':
                    return VUnaryOp('~', operand, w)
                elif op == '!':
                    return VUnaryOp('!', operand, 1)
                elif op == '-':
                    return VUnaryOp('-', operand, w)
            return VConst(0, 32)

        if kind == CursorKind.CONDITIONAL_OPERATOR:
            children = list(cursor.get_children())
            if len(children) == 3:
                sel = self._expr(children[0])
                true_val = self._expr(children[1])
                false_val = self._expr(children[2])
                w = type_width(cursor.type.spelling)
                return VMux(sel, true_val, false_val, w)

        if kind == CursorKind.PAREN_EXPR:
            children = list(cursor.get_children())
            if children:
                return self._expr(children[0])

        if kind in (CursorKind.CSTYLE_CAST_EXPR, CursorKind.UNEXPOSED_EXPR):
            children = list(cursor.get_children())
            if children:
                return self._expr(children[0])

        # Array subscript: a[i]
        if kind == CursorKind.ARRAY_SUBSCRIPT_EXPR:
            self.warnings.append("array subscript — will need memory interface")
            children = list(cursor.get_children())
            if len(children) == 2:
                return VConst(0, type_width(cursor.type.spelling))

        self.warnings.append(f"unhandled AST node: {kind.name} at {cursor.location}")
        return VConst(0, 32)

    def _handle_if(self, cursor) -> Optional[VNode]:
        """Convert if/else to MUX chain."""
        children = list(cursor.get_children())
        if len(children) >= 2:
            cond = self._expr(children[0])
            # True branch
            true_expr = self._walk_body(children[1]) if children[1].kind == CursorKind.COMPOUND_STMT else self._expr(children[1])
            # False branch (else)
            false_expr = None
            if len(children) >= 3:
                false_expr = self._walk_body(children[2]) if children[2].kind == CursorKind.COMPOUND_STMT else self._expr(children[2])
            if true_expr and false_expr:
                return VMux(cond, true_expr, false_expr, 32)
            return true_expr
        return None

    def _handle_for(self, cursor) -> Optional[VNode]:
        """Placeholder for loop unrolling."""
        self.warnings.append("for loop not yet unrolled — emitting placeholder")
        return VConst(0, 32)


# ---- Verilog emitter ----

class VerilogEmitter:
    """Emit synthesizable Verilog from VNode tree."""

    def __init__(self, module_name: str):
        self.module_name = module_name
        self.wire_id = 0
        self.wires: List[str] = []
        self.assigns: List[str] = []

    def emit(self, params: List[Tuple[str, int, bool]], return_expr: VNode,
             return_width: int, local_wires: List[VWire]) -> str:
        lines = []

        # Module declaration
        ports = []
        for name, width, signed in params:
            s = "signed " if signed else ""
            if width == 1:
                ports.append(f"  input {s}{name}")
            else:
                ports.append(f"  input {s}[{width-1}:0] {name}")

        s = "signed " if return_width > 1 else ""
        if return_width == 1:
            ports.append(f"  output {s}result")
        else:
            ports.append(f"  output {s}[{return_width-1}:0] result")

        lines.append(f"module {self.module_name}(")
        lines.append(",\n".join(ports))
        lines.append(");")
        lines.append("")

        # Local wires
        for w in local_wires:
            expr_str = self._node_to_expr(w.expr)
            if w.width == 1:
                lines.append(f"  wire {w.name} = {expr_str};")
            else:
                lines.append(f"  wire [{w.width-1}:0] {w.name} = {expr_str};")

        # Any generated intermediate wires
        for w in self.wires:
            lines.append(w)

        lines.append("")

        # Return assignment
        result_expr = self._node_to_expr(return_expr)
        lines.append(f"  assign result = {result_expr};")
        lines.append("")
        lines.append("endmodule")

        return "\n".join(lines)

    def _node_to_expr(self, node: VNode) -> str:
        if isinstance(node, VInput):
            return node.name

        if isinstance(node, VConst):
            # Use hex for values that might overflow signed representation
            if node.value >= (1 << (node.width - 1)) or node.value > 0xFFFF:
                return f"{node.width}'h{node.value:X}"
            return f"{node.width}'d{node.value}"

        if isinstance(node, VBinOp):
            left = self._node_to_expr(node.left)
            right = self._node_to_expr(node.right)
            return f"({left} {node.op} {right})"

        if isinstance(node, VUnaryOp):
            operand = self._node_to_expr(node.operand)
            return f"({node.op}{operand})"

        if isinstance(node, VMux):
            sel = self._node_to_expr(node.sel)
            true_v = self._node_to_expr(node.true_val)
            false_v = self._node_to_expr(node.false_val)
            return f"({sel} ? {true_v} : {false_v})"

        if isinstance(node, VCast):
            return self._node_to_expr(node.operand)

        if isinstance(node, VWire):
            return node.name

        return "0 /* unknown */"


# ---- AXI-Lite wrapper ----

def emit_axi_wrapper(module_name: str, params: List[Tuple[str, int, bool]],
                     return_width: int) -> str:
    """Generate an AXI-Lite slave wrapper around the combinational module."""
    lines = []
    lines.append(f"// AXI-Lite wrapper for {module_name}")
    lines.append(f"// Register map:")
    offset = 0
    for name, width, _ in params:
        lines.append(f"//   0x{offset:02x}: {name} ({width} bits, write)")
        offset += 4
    lines.append(f"//   0x{offset:02x}: result ({return_width} bits, read)")
    lines.append(f"//   0x{offset+4:02x}: control (bit 0 = start, read: bit 0 = done)")
    lines.append("")
    lines.append(f"// For full AXI-Lite implementation, see Xilinx UG1118 or")
    lines.append(f"// use Vivado 'Create and Package New IP' with this module as the core.")
    lines.append("")

    # Instantiation template
    lines.append(f"// Instantiation:")
    ports = ", ".join(f".{name}({name}_reg)" for name, _, _ in params)
    lines.append(f"//   {module_name} u_{module_name}({ports}, .result(result_wire));")

    return "\n".join(lines)


# ---- Main ----

def parse_and_convert(source_file: str, func_name: str, extra_args=None):
    """Parse C file and convert named function to Verilog."""
    idx = clang.cindex.Index.create()
    args = ['-x', 'c', '-std=c11']
    if extra_args:
        args.extend(extra_args)

    tu = idx.parse(source_file, args=args)

    # Find the target function
    target = None
    for cursor in tu.cursor.get_children():
        if (cursor.kind == CursorKind.FUNCTION_DECL and
            cursor.spelling == func_name and
            cursor.is_definition()):
            target = cursor
            break

    if not target:
        available = [c.spelling for c in tu.cursor.get_children()
                     if c.kind == CursorKind.FUNCTION_DECL and c.is_definition()]
        print(f"Function '{func_name}' not found. Available: {', '.join(available)}",
              file=sys.stderr)
        return None

    conv = C2VConverter()
    params, return_expr, return_width = conv.convert_function(target)

    emitter = VerilogEmitter(func_name)
    verilog = emitter.emit(params, return_expr, return_width, conv.wires)

    return verilog, conv.warnings, params, return_width


def main():
    parser = argparse.ArgumentParser(
        description="Convert C functions to synthesizable Verilog",
    )
    parser.add_argument("input", help="C source file")
    parser.add_argument("-f", "--function", required=True, help="Function name")
    parser.add_argument("-o", "--output", help="Output Verilog file (default: stdout)")
    parser.add_argument("--axi", action="store_true", help="Generate AXI-Lite wrapper info")
    parser.add_argument("--list", action="store_true", help="List functions in source file")
    parser.add_argument("-I", action="append", default=[], help="Include path")
    args = parser.parse_args()

    if args.list:
        idx = clang.cindex.Index.create()
        tu = idx.parse(args.input, args=['-x', 'c', '-std=c11'])
        for c in tu.cursor.get_children():
            if c.kind == CursorKind.FUNCTION_DECL and c.is_definition():
                print(f"  {c.spelling}({c.type.spelling})")
        return

    extra = [f"-I{d}" for d in args.I]
    result = parse_and_convert(args.input, args.function, extra)

    if not result:
        sys.exit(1)

    verilog, warnings, params, ret_width = result

    for w in warnings:
        print(f"// WARNING: {w}", file=sys.stderr)

    output = verilog
    if args.axi:
        output += "\n\n" + emit_axi_wrapper(args.function, params, ret_width)

    if args.output:
        with open(args.output, 'w') as f:
            f.write(output + "\n")
        print(f"Wrote {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
