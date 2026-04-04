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

@dataclass
class VIndex(VNode):
    """Array index: array[idx] → bit-select on wide port."""
    array: VNode
    index: VNode
    elem_width: int  # width of each element
    width: int

@dataclass
class VConcat(VNode):
    """Verilog concatenation {a, b, ...}"""
    parts: list  # List[VNode]
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
        self.local_arrays: Dict[str, List[VNode]] = {}  # name → [elem0, elem1, ...]
        self.struct_fields: Dict[str, Dict[str, VNode]] = {}  # var → {field → expr}
        self.wires: List[VWire] = []
        self.wire_counter = 0
        self.warnings: List[str] = []
        self.ret_struct_fields: Optional[List[Tuple[str, int]]] = None  # [(name, width)]

    def convert_function(self, cursor):
        """Convert a function cursor.
        Returns (params, return_expr_or_dict, return_width).
        For struct returns, return_expr is a dict {field_name: VNode}."""
        params = []
        body = None
        ret_type = cursor.result_type
        ret_width = type_width(ret_type.spelling)

        # Check for struct return type
        ret_struct = self._get_struct_fields(ret_type)
        if ret_struct:
            self.ret_struct_fields = ret_struct

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

        # For struct returns, collect field assignments
        if self.ret_struct_fields:
            # Find the return variable and its field assignments
            for var_name, fields in self.struct_fields.items():
                if fields:
                    return {
                        "fields": {name: fields.get(name, VConst(0, w))
                                   for name, w in self.ret_struct_fields},
                        "struct_fields": self.ret_struct_fields,
                    }

        if return_expr is None:
            raise ValueError("No return statement found")

        return params, return_expr, ret_width

    def _get_struct_fields(self, type_obj) -> Optional[List[Tuple[str, int]]]:
        """Extract field names and widths from a struct type."""
        decl = type_obj.get_declaration()
        if not decl or decl.kind != CursorKind.STRUCT_DECL:
            # Try canonical type
            canon = type_obj.get_canonical()
            decl = canon.get_declaration()
            if not decl or decl.kind not in (CursorKind.STRUCT_DECL, CursorKind.TYPEDEF_DECL):
                return None
        fields = []
        for child in decl.get_children():
            if child.kind == CursorKind.FIELD_DECL:
                fields.append((child.spelling, type_width(child.type.spelling)))
        return fields if fields else None

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
                        type_str = decl.type.spelling
                        w = type_width(type_str)
                        # Check for array type: e.g. "uint64_t [4]"
                        if '[' in type_str:
                            # Extract array size
                            try:
                                arr_size = int(type_str.split('[')[1].split(']')[0])
                                elem_type = type_str.split('[')[0].strip()
                                elem_w = type_width(elem_type)
                                self.local_arrays[name] = [VConst(0, elem_w)] * arr_size
                            except (ValueError, IndexError):
                                pass
                            continue
                        children = list(decl.get_children())
                        # Skip TYPE_REF children
                        init_children = [c for c in children if c.kind != CursorKind.TYPE_REF]
                        if init_children:
                            expr = self._expr(init_children[-1])
                            self.locals[name] = expr
                            self.wires.append(VWire(name, expr, w))
                        else:
                            # Declaration without initializer — register with zero
                            self.locals[name] = VConst(0, w)
            elif stmt.kind == CursorKind.BINARY_OPERATOR and self._is_assignment(stmt):
                children = list(stmt.get_children())
                if len(children) == 2:
                    left = children[0]
                    # Unwrap UNEXPOSED_EXPR
                    left_raw = left
                    while left_raw.kind == CursorKind.UNEXPOSED_EXPR:
                        c = list(left_raw.get_children())
                        if c: left_raw = c[0]
                        else: break

                    rhs = self._expr(children[1])
                    w = type_width(stmt.type.spelling)

                    if left_raw.kind == CursorKind.MEMBER_REF_EXPR:
                        # Struct field assignment: r.abits = expr
                        field_name = left_raw.spelling
                        member_children = list(left_raw.get_children())
                        var_name = member_children[0].spelling if member_children else "?"
                        if var_name not in self.struct_fields:
                            self.struct_fields[var_name] = {}
                        self.struct_fields[var_name][field_name] = rhs
                        wire_name = f"{var_name}_{field_name}"
                        self.wires.append(VWire(wire_name, rhs, w))
                    elif left_raw.kind == CursorKind.ARRAY_SUBSCRIPT_EXPR:
                        # Array element assignment: vals[0] = a
                        arr_children = list(left_raw.get_children())
                        if len(arr_children) == 2:
                            arr_name = arr_children[0].spelling
                            idx_node = self._expr(arr_children[1])
                            if arr_name in self.local_arrays and isinstance(idx_node, VConst):
                                idx = idx_node.value
                                if idx < len(self.local_arrays[arr_name]):
                                    self.local_arrays[arr_name][idx] = rhs
                    else:
                        # Simple assignment: x = expr
                        target_name = left.spelling
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
                self._handle_for(stmt)

        return return_expr

    def _is_assignment(self, cursor) -> bool:
        """Check if a BINARY_OPERATOR is a plain assignment (=).
        Handles both simple vars (x = expr) and struct fields (r.field = expr)."""
        children = list(cursor.get_children())
        if len(children) != 2:
            return False
        left = children[0]
        # Unwrap UNEXPOSED_EXPR
        while left.kind == CursorKind.UNEXPOSED_EXPR:
            c = list(left.get_children())
            if c:
                left = c[0]
            else:
                break
        # Accept DECL_REF_EXPR (simple var), MEMBER_REF_EXPR (struct field),
        # or ARRAY_SUBSCRIPT_EXPR (array element)
        if left.kind == CursorKind.DECL_REF_EXPR:
            name = left.spelling
            if name not in self.locals and name not in self.params:
                return False
        elif left.kind == CursorKind.MEMBER_REF_EXPR:
            pass  # struct field assignment — always accept
        elif left.kind == CursorKind.ARRAY_SUBSCRIPT_EXPR:
            pass  # array element assignment — always accept
        else:
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

        if kind == CursorKind.CSTYLE_CAST_EXPR:
            children = list(cursor.get_children())
            if children:
                inner = self._expr(children[-1])
                cast_width = type_width(cursor.type.spelling)
                if isinstance(inner, VConst):
                    return VConst(inner.value, cast_width)
                if hasattr(inner, 'width') and inner.width != cast_width:
                    return VCast(inner, cast_width)
                return inner

        if kind == CursorKind.UNEXPOSED_EXPR:
            children = list(cursor.get_children())
            if children:
                return self._expr(children[0])

        # Array subscript: a[i] → bit-select on wide port or local array
        if kind == CursorKind.ARRAY_SUBSCRIPT_EXPR:
            children = list(cursor.get_children())
            if len(children) == 2:
                array_expr = children[0]
                index_expr = children[1]
                elem_width = type_width(cursor.type.spelling)
                # If array is a known local, use the index to select
                arr_name = array_expr.spelling if array_expr.spelling else None
                idx_node = self._expr(index_expr)
                if arr_name and arr_name in self.locals:
                    return VIndex(self.locals[arr_name], idx_node, elem_width, elem_width)
                if arr_name and arr_name in self.params:
                    w, _ = self.params[arr_name]
                    return VIndex(VInput(arr_name, w), idx_node, elem_width, elem_width)
                # Constant index on local array — try to resolve directly
                if isinstance(idx_node, VConst) and arr_name and arr_name in self.local_arrays:
                    arr = self.local_arrays[arr_name]
                    if idx_node.value < len(arr):
                        return arr[idx_node.value]
                arr_node = self._expr(array_expr)
                return VIndex(arr_node, idx_node, elem_width, elem_width)

        # Function call → module instantiation (record as warning for now,
        # emit as inline comment; full support needs separate modules)
        if kind == CursorKind.CALL_EXPR:
            func_name = cursor.spelling
            children = list(cursor.get_children())
            args = [self._expr(c) for c in children[1:]]  # skip the function ref
            w = type_width(cursor.type.spelling)
            self.warnings.append(f"function call '{func_name}' — needs module instantiation")
            # For known simple builtins, try to inline
            if func_name == '__builtin_expect' and len(args) >= 1:
                return args[0]
            return VConst(0, w)

        # Member access: x.field (read, not assignment)
        if kind == CursorKind.MEMBER_REF_EXPR:
            field_name = cursor.spelling
            children = list(cursor.get_children())
            if children:
                var_name = children[0].spelling
                # Check if we have this field tracked
                if var_name in self.struct_fields and field_name in self.struct_fields[var_name]:
                    return self.struct_fields[var_name][field_name]
                if var_name in self.locals:
                    return self.locals[var_name]
            return VConst(0, type_width(cursor.type.spelling))

        # Type reference (harmless, skip)
        if kind == CursorKind.TYPE_REF:
            return VConst(0, 32)

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

    def _handle_for(self, cursor):
        """Unroll a bounded for loop.

        Expects: for (var = start; var < end; var++) { body }
        Unrolls by substituting the loop variable with each constant value
        and walking the body for each iteration.
        """
        children = list(cursor.get_children())
        if len(children) != 4:
            self.warnings.append(f"for loop with {len(children)} children (expected 4)")
            return

        init_stmt, cond_stmt, incr_stmt, body_stmt = children

        # Extract loop variable and start value from init: i = 0
        loop_var = None
        start_val = 0
        init_tokens = [t.spelling for t in init_stmt.get_tokens()]
        if '=' in init_tokens:
            eq_idx = init_tokens.index('=')
            if eq_idx > 0 and eq_idx + 1 < len(init_tokens):
                loop_var = init_tokens[eq_idx - 1]
                try:
                    start_val = int(init_tokens[eq_idx + 1], 0)
                except ValueError:
                    pass

        # Extract bound from condition: i < N
        end_val = 0
        cond_tokens = [t.spelling for t in cond_stmt.get_tokens()]
        for op in ('<', '<=', '!='):
            if op in cond_tokens:
                op_idx = cond_tokens.index(op)
                if op_idx + 1 < len(cond_tokens):
                    try:
                        end_val = int(cond_tokens[op_idx + 1], 0)
                        if op == '<=':
                            end_val += 1
                    except ValueError:
                        pass
                break

        if not loop_var or end_val <= start_val:
            self.warnings.append(f"cannot unroll for loop: var={loop_var} start={start_val} end={end_val}")
            return

        if end_val - start_val > 1024:
            self.warnings.append(f"for loop too large to unroll: {end_val - start_val} iterations")
            return

        # Unroll: for each iteration, set the loop variable to the constant
        # value and walk the body.
        for i in range(start_val, end_val):
            self.locals[loop_var] = VConst(i, 32)
            self._walk_body(body_stmt) if body_stmt.kind == CursorKind.COMPOUND_STMT else None
            # Also handle single-statement body (no compound)
            if body_stmt.kind == CursorKind.COMPOUND_STMT:
                pass  # already walked above
            elif body_stmt.kind == CursorKind.COMPOUND_ASSIGNMENT_OPERATOR:
                # Single compound assignment in loop body
                stmt = body_stmt
                children_b = list(stmt.get_children())
                if len(children_b) == 2:
                    target_name = children_b[0].spelling
                    rhs = self._expr(children_b[1])
                    tokens = list(stmt.get_tokens())
                    op = None
                    for tok in tokens:
                        if tok.spelling.endswith('=') and len(tok.spelling) >= 2 and tok.spelling != '==':
                            op = tok.spelling[:-1]
                            break
                    if op and target_name in self.locals:
                        old_val = self.locals[target_name]
                        w = type_width(stmt.type.spelling)
                        new_expr = VBinOp(C_TO_V_OPS.get(op, op), old_val, rhs, w)
                        self.wire_counter += 1
                        self.locals[target_name] = new_expr
                        self.wires.append(VWire(f"{target_name}_{self.wire_counter}", new_expr, w))


# ---- Verilog emitter ----

class VerilogEmitter:
    """Emit synthesizable Verilog from VNode tree."""

    def __init__(self, module_name: str):
        self.module_name = module_name
        self.wire_id = 0
        self.wires: List[str] = []
        self.assigns: List[str] = []

    def emit(self, params: List[Tuple[str, int, bool]], return_expr,
             return_width: int, local_wires: List[VWire]) -> str:
        lines = []

        # Check if return_expr is a struct (dict with "fields")
        is_struct_return = isinstance(return_expr, dict) and "fields" in return_expr

        # Module declaration
        ports = []
        for name, width, signed in params:
            s = "signed " if signed else ""
            if width == 1:
                ports.append(f"  input {s}{name}")
            else:
                ports.append(f"  input {s}[{width-1}:0] {name}")

        if is_struct_return:
            for field_name, field_width in return_expr["struct_fields"]:
                if field_width == 1:
                    ports.append(f"  output {field_name}")
                else:
                    ports.append(f"  output [{field_width-1}:0] {field_name}")
        else:
            s = "signed " if return_width > 1 else ""
            if return_width == 1:
                ports.append(f"  output {s}result")
            else:
                ports.append(f"  output {s}[{return_width-1}:0] result")

        lines.append(f"module {self.module_name}(")
        lines.append(",\n".join(ports))
        lines.append(");")
        lines.append("")

        # Collect port names to avoid wire conflicts
        port_names = set(n for n, _, _ in params)
        port_names.add("result")
        if is_struct_return:
            for fn, _ in return_expr["struct_fields"]:
                port_names.add(fn)

        # Local wires (skip if name conflicts with port)
        for w in local_wires:
            if w.name in port_names:
                continue  # this wire is used directly in the assign
            expr_str = self._node_to_expr(w.expr)
            if w.width == 1:
                lines.append(f"  wire {w.name} = {expr_str};")
            else:
                lines.append(f"  wire [{w.width-1}:0] {w.name} = {expr_str};")

        # Pre-evaluate return expression to collect any cast wires
        if is_struct_return:
            assign_lines = []
            for field_name, _ in return_expr["struct_fields"]:
                field_expr = return_expr["fields"].get(field_name)
                if field_expr:
                    assign_lines.append(f"  assign {field_name} = {self._node_to_expr(field_expr)};")
        else:
            result_expr_str = self._node_to_expr(return_expr)
            assign_lines = [f"  assign result = {result_expr_str};"]

        # Emit any wires generated during expression evaluation (e.g., casts)
        for w in self.wires:
            lines.append(w)

        lines.append("")
        for al in assign_lines:
            lines.append(al)
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
            inner = self._node_to_expr(node.operand)
            # Truncation: take lower bits
            if hasattr(node.operand, 'width') and node.width < node.operand.width:
                # If inner is a simple name, use direct bit-select
                # Otherwise wrap in a wire first (Verilog can't bit-select expressions directly)
                if inner.isidentifier():
                    return f"{inner}[{node.width-1}:0]"
                else:
                    self.wire_id += 1
                    wname = f"_cast_{self.wire_id}"
                    ow = node.operand.width
                    self.wires.append(f"  wire [{ow-1}:0] {wname} = {inner};")
                    return f"{wname}[{node.width-1}:0]"
            return inner

        if isinstance(node, VWire):
            return node.name

        if isinstance(node, VIndex):
            arr = self._node_to_expr(node.array)
            idx = self._node_to_expr(node.index)
            ew = node.elem_width
            return f"{arr}[{idx}*{ew} +: {ew}]"

        if isinstance(node, VConcat):
            parts = ", ".join(self._node_to_expr(p) for p in node.parts)
            return f"{{{parts}}}"

        return "0 /* unknown */"


# ---- NCL (NULL Convention Logic) VHDL emitter ----

class NclEmitter:
    """Emit VHDL with NCL dual-rail types for asynchronous execution."""

    def __init__(self, module_name):
        self.module_name = module_name
        self.wire_id = 0
        self.signals = []

    def emit(self, params, return_expr, ret_width, local_wires):
        """Emit VHDL entity + architecture using ncl_logic_vector."""
        lines = []
        lines.append(f"-- NCL (async) version of {self.module_name}")
        lines.append(f"-- Generated by c2v --ncl")
        lines.append(f"library IEEE;")
        lines.append(f"use IEEE.std_logic_1164.all;")
        lines.append(f"library async_ncl;")
        lines.append(f"use async_ncl.ncl.all;")
        lines.append(f"")

        # Entity
        ports = []
        for name, width, signed in params:
            ports.append(f"    {name} : in ncl_logic_vector({width-1} downto 0)")
        ports.append(f"    result : out ncl_logic_vector({ret_width-1} downto 0)")

        lines.append(f"entity {self.module_name}_ncl is")
        lines.append(f"  port (")
        lines.append(";\n".join(ports))
        lines.append(f"  );")
        lines.append(f"end entity {self.module_name}_ncl;")
        lines.append(f"")

        # Architecture
        lines.append(f"architecture ncl_comb of {self.module_name}_ncl is")

        # Local signal declarations
        port_names = set(n for n, _, _ in params)
        port_names.add("result")
        for w in local_wires:
            if w.name in port_names:
                continue
            lines.append(f"  signal {w.name} : ncl_logic_vector({w.width-1} downto 0);")

        lines.append(f"begin")

        # Local wire assignments
        for w in local_wires:
            if w.name in port_names:
                continue
            expr = self._expr(w.expr, w.width)
            lines.append(f"  {w.name} <= {expr};")

        # Result assignment
        if isinstance(return_expr, dict):
            # struct return — not supported in NCL yet
            lines.append(f"  -- struct returns not yet supported in NCL")
            lines.append(f"  result <= (others => (L => '0', H => '0'));")
        else:
            expr = self._expr(return_expr, ret_width)
            lines.append(f"  result <= {expr};")

        lines.append(f"end architecture ncl_comb;")
        return "\n".join(lines)

    def _expr(self, node, width=32):
        """Convert a VNode expression tree to NCL VHDL."""
        if isinstance(node, VInput):
            return node.name

        if isinstance(node, VConst):
            # Encode a constant as NCL: ncl_encode(std_logic_vector)
            val = node.value & ((1 << node.width) - 1)
            hex_str = f"X\"{val:0{(node.width+3)//4}X}\""
            return f"ncl_encode(std_logic_vector'({hex_str}))"

        if isinstance(node, VBinOp):
            left = self._expr(node.left, node.width)
            right = self._expr(node.right, node.width)
            op = node.op

            # Map Verilog operators to NCL
            if op in ('&',):
                return f"({left} and {right})"
            elif op in ('|',):
                return f"({left} or {right})"
            elif op in ('^',):
                return f"({left} xor {right})"
            elif op == '+':
                # Addition needs an NCL adder — use ncl_add helper
                return f"ncl_add({left}, {right})"
            elif op == '-':
                return f"ncl_sub({left}, {right})"
            elif op == '*':
                return f"ncl_mul({left}, {right})"
            elif op in ('<<', '>>'):
                return f"ncl_shift({left}, {right}, \"{op}\")"
            elif op in ('<', '>', '<=', '>=', '==', '!='):
                return f"ncl_compare({left}, {right}, \"{op}\")"
            elif op in ('&&', '||'):
                ncl_op = "and" if op == '&&' else "or"
                return f"({left} {ncl_op} {right})"
            else:
                return f"-- unsupported op: {op}"

        if isinstance(node, VUnaryOp):
            operand = self._expr(node.operand, node.width)
            if node.op == '~':
                return f"(not {operand})"
            elif node.op == '!':
                return f"(not {operand})"
            elif node.op == '-':
                return f"ncl_negate({operand})"
            return f"-- unsupported unary: {node.op}"

        if isinstance(node, VMux):
            sel = self._expr(node.sel, 1)
            true_v = self._expr(node.true_val, node.width)
            false_v = self._expr(node.false_val, node.width)
            return f"ncl_mux({sel}, {true_v}, {false_v})"

        if isinstance(node, VCast):
            inner = self._expr(node.operand, getattr(node.operand, 'width', node.width))
            if hasattr(node.operand, 'width') and node.width < node.operand.width:
                return f"{inner}({node.width-1} downto 0)"
            return inner

        if isinstance(node, VWire):
            return node.name

        if isinstance(node, VConcat):
            # NCL concatenation: combine dual-rail vectors
            parts = " & ".join(self._expr(p, getattr(p, 'width', 32)) for p in node.parts)
            return f"({parts})"

        if isinstance(node, VIndex):
            arr = self._expr(node.array, 32)
            idx = self._expr(node.index, 32)
            ew = node.elem_width
            return f"ncl_slice({arr}, {idx}, {ew})"

        return f"-- unknown node"


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
    result = conv.convert_function(target)

    # Struct return: result is (params, dict, ret_width) where dict has "fields"
    if isinstance(result, dict):
        # Struct return — params are on the converter
        params = [(n, w, s) for n, (w, s) in conv.params.items()]
        return_expr = result
        ret_width = sum(w for _, w in result["struct_fields"])
    else:
        params, return_expr, ret_width = result

    emitter = VerilogEmitter(func_name)
    verilog = emitter.emit(params, return_expr, ret_width, conv.wires)

    return verilog, conv.warnings, params, ret_width


def emit_fpga_build(func_name, verilog, params, ret_width, fpga_dir=None):
    """Generate a complete FPGA build directory for the given function.

    Creates:
      <dir>/<func>.v           — c2v-generated combinational module
      <dir>/accel_slot_inst.v  — wires c2v module into accel_slot
      <dir>/build.sh           — one-shot Quartus compile + program script
    """
    # Find ldx project root (parent of python/)
    ldx_root = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))

    if fpga_dir is None:
        fpga_dir = os.path.join(ldx_root, "fpga", "build", func_name)
    os.makedirs(fpga_dir, exist_ok=True)

    n_args = len(params)

    # 1. Write the c2v Verilog module
    func_v = os.path.join(fpga_dir, f"{func_name}.v")
    with open(func_v, 'w') as f:
        f.write(verilog + "\n")
    print(f"  Wrote {func_v}", file=sys.stderr)

    # 2. Generate accel_slot wiring that instantiates the c2v module
    port_lines = []
    for i, (name, width, signed) in enumerate(params):
        port_lines.append(f"    .{name}(arg_reg[{i}][{width-1}:0])")
    ports = ",\n".join(port_lines)

    # The result wire declaration needs to match accel_slot's expectation
    inst_v = os.path.join(fpga_dir, "accel_slot_inst.v")
    with open(inst_v, 'w') as f:
        f.write(f"""// Auto-generated: wires {func_name} into accel_slot.
// Include this in the accel_slot module or use the patched top-level.
//
// accel_slot parameters: N_ARGS={n_args}, RET_WIDTH={ret_width}

{func_name} u_func (
{ports},
    .result(result)
);
""")
    print(f"  Wrote {inst_v}", file=sys.stderr)

    # 3. Generate a patched top-level that sets the right parameters
    top_v = os.path.join(fpga_dir, "ldx_top_inst.v")
    with open(top_v, 'w') as f:
        f.write(f"""// Auto-generated top-level parameters for {func_name}.
// This file is `include'd or used to parameterize the build.
//
// Function: {func_name}
// Arguments: {n_args} x 32-bit
// Return: {ret_width}-bit
//
// accel_slot #(.N_ARGS({n_args}), .RET_WIDTH({ret_width}))

`define LDX_FUNC_NAME    "{func_name}"
`define LDX_N_ARGS       {n_args}
`define LDX_RET_WIDTH    {ret_width}
""")
    print(f"  Wrote {top_v}", file=sys.stderr)

    # 4. Generate build script
    quartus_bin = os.path.expanduser("~/altera_lite/25.1std/quartus/bin")
    quartus_dir = os.path.join(ldx_root, "fpga", "quartus")

    build_sh = os.path.join(fpga_dir, "build.sh")
    with open(build_sh, 'w') as f:
        f.write(f"""#!/bin/bash
# Auto-generated build script for {func_name} → FPGA.
# Usage: bash build.sh [--program]
set -e

QUARTUS_BIN="{quartus_bin}"
PROJECT_DIR="{quartus_dir}"
FUNC_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="ldx_accel"

export PATH="$QUARTUS_BIN:$PATH"

echo "=== ldx FPGA build: {func_name} ==="
echo "  {n_args} args, {ret_width}-bit return"

# Copy function Verilog into project
cp "$FUNC_DIR/{func_name}.v" "$PROJECT_DIR/"

# Add function source to project (idempotent)
cd "$PROJECT_DIR"
quartus_sh -t - <<'TCLEOF'
package require ::quartus::project
project_open $PROJECT_NAME
# Remove old function files, add new one
catch {{ set_global_assignment -name VERILOG_FILE -remove {func_name}.v }}
set_global_assignment -name VERILOG_FILE {func_name}.v
project_close
TCLEOF

echo "[1/4] Analysis & Synthesis..."
quartus_map $PROJECT_NAME

echo "[2/4] Fitter..."
quartus_fit $PROJECT_NAME

echo "[3/4] Timing Analysis..."
quartus_sta $PROJECT_NAME

echo "[4/4] Assembler..."
quartus_asm $PROJECT_NAME

echo "=== Build complete ==="
echo "Bitstream: $PROJECT_DIR/output_files/$PROJECT_NAME.sof"

if [ "$1" = "--program" ]; then
    echo "Programming FPGA via JTAG..."
    quartus_pgm -c "USB-Blaster" -m JTAG -o "P;output_files/$PROJECT_NAME.sof"
    echo "Done — FPGA programmed with {func_name}"
fi
""")
    os.chmod(build_sh, 0o755)
    print(f"  Wrote {build_sh}", file=sys.stderr)

    # 5. Print register map
    print(f"\n  FPGA register map for {func_name}:", file=sys.stderr)
    for i, (name, width, signed) in enumerate(params):
        print(f"    0x{i*4:02X}: {name} ({width}-bit, write)", file=sys.stderr)
    print(f"    0x40: result ({ret_width}-bit, read)", file=sys.stderr)
    print(f"    0x48: status (bit 0 = valid)", file=sys.stderr)
    print(f"\n  Build:   bash {build_sh}", file=sys.stderr)
    print(f"  Program: bash {build_sh} --program", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(
        description="Convert C functions to synthesizable Verilog",
    )
    parser.add_argument("input", help="C source file")
    parser.add_argument("-f", "--function", required=True, help="Function name")
    parser.add_argument("-o", "--output", help="Output Verilog file (default: stdout)")
    parser.add_argument("--axi", action="store_true", help="Generate AXI-Lite wrapper info")
    parser.add_argument("--ncl", action="store_true",
                        help="Generate NCL (NULL Convention Logic) VHDL for async execution")
    parser.add_argument("--fpga", action="store_true",
                        help="Generate FPGA build: accel_slot wiring + Quartus build script")
    parser.add_argument("--fpga-dir", default=None,
                        help="Output directory for FPGA build files (default: fpga/build/<func>)")
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

    if args.ncl:
        # Re-parse and emit NCL VHDL instead of Verilog
        result2 = parse_and_convert(args.input, args.function, extra)
        if result2:
            _, _, ncl_params, ncl_ret_width = result2
            # Get the raw expression tree by re-running the converter
            import clang.cindex as _ci
            _idx = _ci.Index.create()
            _tu = _idx.parse(args.input, args=['-x', 'c', '-std=c11'] + extra)
            _target = None
            for _c in _tu.cursor.get_children():
                if (_c.kind == _ci.CursorKind.FUNCTION_DECL and
                    _c.spelling == args.function and _c.is_definition()):
                    _target = _c; break
            if _target:
                conv = C2VConverter()
                raw = conv.convert_function(_target)
                if isinstance(raw, dict):
                    print("NCL: struct returns not yet supported", file=sys.stderr)
                else:
                    raw_params, return_expr, raw_ret_width = raw
                    ncl_emitter = NclEmitter(args.function)
                    ncl_out = ncl_emitter.emit(
                        [(n, w, s) for n, (w, s) in conv.params.items()],
                        return_expr, raw_ret_width, conv.wires)
                    if args.output:
                        outfile = args.output
                        if outfile.endswith('.v'): outfile = outfile[:-2] + '.vhdl'
                        with open(outfile, 'w') as f:
                            f.write(ncl_out + "\n")
                        print(f"Wrote {outfile}", file=sys.stderr)
                    else:
                        print(ncl_out)
        sys.exit(0)

    output = verilog
    if args.axi:
        output += "\n\n" + emit_axi_wrapper(args.function, params, ret_width)

    if args.fpga:
        emit_fpga_build(args.function, verilog, params, ret_width, args.fpga_dir)
    elif args.output:
        with open(args.output, 'w') as f:
            f.write(output + "\n")
        print(f"Wrote {args.output}", file=sys.stderr)
    else:
        print(output)


if __name__ == "__main__":
    main()
