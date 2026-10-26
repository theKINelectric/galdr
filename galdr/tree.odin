package galdr

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Tree: an outline you can expand and collapse, with guide lines.
// File_Picker is a Tree of the file system that loads directories lazily.

Tree_Node :: struct {
	label:    string, // owned
	icon:     string, // optional glyph, e.g. "▤"
	children: [dynamic]^Tree_Node,
	parent:   ^Tree_Node,
	expanded: bool,
	branch:   bool, // can have children even before they're loaded
	loaded:   bool, // children have been populated (for lazy trees)
	user:     rawptr,
	id:       int,
}

Tree_Row :: struct {
	node:  ^Tree_Node,
	depth: int,
	last:  u64, // bit d set: the ancestor at depth d is the last of its siblings
}

Tree :: struct {
	roots:   [dynamic]^Tree_Node,
	list:    Pick_List,
	rows:    [dynamic]Tree_Row, // visible rows, rebuilt by tree_flatten
	on_open: proc(t: ^Tree, n: ^Tree_Node), // called before a branch expands (lazy loading)
	user:    rawptr,
}

// tree_add creates a node under parent (nil = a root). label is copied.
tree_add :: proc(t: ^Tree, parent: ^Tree_Node, label: string, branch := false, icon := "") -> ^Tree_Node {
	n := new(Tree_Node)
	n.label = strings.clone(label)
	n.icon = icon
	n.parent = parent
	n.branch = branch
	if parent == nil {
		append(&t.roots, n)
	} else {
		append(&parent.children, n)
		parent.branch = true
		parent.loaded = true
	}
	// Structural mutations keep the visible-row cache coherent: a new child
	// under an expanded parent is visible immediately, and no cached row can
	// ever point at freed memory.
	if parent == nil || parent.expanded do tree_flatten(t)
	return n
}

@(private)
_node_free :: proc(n: ^Tree_Node) {
	for c in n.children do _node_free(c)
	delete(n.children)
	delete(n.label)
	free(n)
}

// tree_clear_children frees a node's subtree (for reloading). The Tree is
// required: freeing descendants must invalidate Tree.rows, which caches
// pointers into the freed nodes, and clamp the selection into what remains.
// The node stays expanded, so an in-place reload (clear, then tree_add)
// keeps the new children visible.
tree_clear_children :: proc(t: ^Tree, n: ^Tree_Node) {
	for c in n.children do _node_free(c)
	clear(&n.children)
	n.loaded = false
	tree_flatten(t)
}

tree_destroy :: proc(t: ^Tree) {
	for r in t.roots do _node_free(r)
	delete(t.roots)
	delete(t.rows)
}

// tree_flatten rebuilds the visible rows from the expanded state.
tree_flatten :: proc(t: ^Tree) {
	clear(&t.rows)
	walk :: proc(t: ^Tree, nodes: []^Tree_Node, depth: int, last: u64) {
		for n, i in nodes {
			is_last := i == len(nodes) - 1
			bits := last
			if is_last && depth < 64 do bits |= 1 << uint(depth)
			append(&t.rows, Tree_Row{n, depth, bits})
			if n.expanded do walk(t, n.children[:], depth + 1, bits)
		}
	}
	walk(t, t.roots[:], 0, 0)
	t.list.cursor = clamp(t.list.cursor, 0, max(len(t.rows) - 1, 0))
}

tree_selected :: proc(t: ^Tree) -> ^Tree_Node {
	if t.list.cursor < 0 || t.list.cursor >= len(t.rows) do return nil
	return t.rows[t.list.cursor].node
}

tree_expand :: proc(t: ^Tree, n: ^Tree_Node, open: bool) {
	if n == nil || !n.branch do return
	if open && !n.loaded && t.on_open != nil do t.on_open(t, n)
	n.expanded = open
	tree_flatten(t)
}

// tree_on_key: ↑↓ move, → expands or enters, ← collapses or goes to the
// parent, space/enter toggles a branch.
tree_on_key :: proc(t: ^Tree, k: Key) -> bool {
	if len(t.rows) == 0 do tree_flatten(t)
	n := tree_selected(t)
	switch {
	case k.code == .Right, is_char(k, 'l'):
		if n == nil do return false
		if n.branch && !n.expanded {
			tree_expand(t, n, true)
		} else if n.expanded && len(n.children) > 0 {
			t.list.cursor += 1
		}
	case k.code == .Left, is_char(k, 'h'):
		if n == nil do return false
		if n.expanded {
			tree_expand(t, n, false)
		} else if n.parent != nil {
			for row, i in t.rows do if row.node == n.parent do t.list.cursor = i
		}
	case is_char(k, ' '), k.code == .Enter:
		if n == nil || !n.branch do return false
		tree_expand(t, n, !n.expanded)
	case:
		return pick_on_key(&t.list, k, len(t.rows))
	}
	return true
}

tree_draw :: proc(f: ^Frame, r: Rect, t: ^Tree, focused := true, tone: Tone = .Primary) {
	if len(t.rows) == 0 do tree_flatten(t)
	pick_draw_custom(f, r, &t.list, len(t.rows), proc(f: ^Frame, row: Rect, i: int, sel: bool, user: rawptr) {
		t := (^Tree)(user)
		th := f.theme
		tr := t.rows[i]
		x := row.x
		guide := Pen{fg = th.line}
		// Column c continues the ancestor at depth c+1 unless it was the last
		// of its siblings; the final column is this node's own connector.
		bit :: proc(bits: u64, d: int) -> bool { return d < 64 && bits & (1 << uint(d)) != 0 }
		for c in 0 ..< tr.depth - 1 {
			x += text(f, x, row.y, bit(tr.last, c + 1) ? "   " : "│  ", guide)
		}
		if tr.depth > 0 {
			x += text(f, x, row.y, bit(tr.last, tr.depth) ? "└─ " : "├─ ", guide)
		}
		n := tr.node
		marker := "  "
		if n.branch do marker = n.expanded ? "▾ " : "▸ "
		x += text(f, x, row.y, marker, {fg = th.muted})
		if n.icon != "" {
			x += text(f, x, row.y, n.icon, {fg = n.branch ? th.tones[.Accent] : th.muted})
			x += text(f, x, row.y, " ", {})
		}
		p := sel ? Pen{fg = th.ink, attrs = {.Bold}} : Pen{fg = n.branch ? th.ink : th.muted}
		text(f, x, row.y, truncate(n.label, row.x + row.w - x), p)
	}, t, focused, tone)
}

// ------------------------------------------------------------ File_Picker

File_Picker :: struct {
	tree:        Tree,
	root:        string, // owned
	show_hidden: bool,
	extensions:  []string, // e.g. {".md", ".txt"}; empty = all files
	chosen:      string,   // owned; set when a file is picked
}

@(private)
_Entry :: struct {
	name: string,
	dir:  bool,
}

@(private)
_picker_load :: proc(t: ^Tree, n: ^Tree_Node) {
	fp := (^File_Picker)(t.user)
	path := picker_path(fp, n)
	infos, err := os.read_all_directory_by_path(path, context.temp_allocator)
	n.loaded = true
	if err != nil do return
	entries := make([dynamic]_Entry, context.temp_allocator)
	for info in infos {
		if !fp.show_hidden && strings.has_prefix(info.name, ".") do continue
		dir := info.type == .Directory
		if !dir && len(fp.extensions) > 0 {
			ext := filepath.ext(info.name)
			keep := false
			for want in fp.extensions do if strings.equal_fold(ext, want) do keep = true
			if !keep do continue
		}
		append(&entries, _Entry{info.name, dir})
	}
	// Directories first, then by name.
	slice.sort_by(entries[:], proc(a, b: _Entry) -> bool {
		if a.dir != b.dir do return a.dir
		return strings.to_lower(a.name, context.temp_allocator) < strings.to_lower(b.name, context.temp_allocator)
	})
	for e in entries {
		c := tree_add(t, n, e.name, e.dir, e.dir ? "▣" : "▤")
		c.loaded = !e.dir
	}
	n.loaded = true
}

// picker_open shows the directory at root.
picker_open :: proc(fp: ^File_Picker, root: string) {
	tree_destroy(&fp.tree)
	delete(fp.root)
	fp.tree = {}
	fp.root = strings.clone(root)
	fp.tree.user = fp
	fp.tree.on_open = _picker_load
	top := tree_add(&fp.tree, nil, filepath.base(root), true, "▣")
	tree_expand(&fp.tree, top, true)
}

picker_destroy :: proc(fp: ^File_Picker) {
	tree_destroy(&fp.tree)
	delete(fp.root)
	delete(fp.chosen)
}

// picker_path is the file system path of a node.
picker_path :: proc(fp: ^File_Picker, n: ^Tree_Node, allocator := context.temp_allocator) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for cur := n; cur != nil && cur.parent != nil; cur = cur.parent do inject_at(&parts, 0, cur.label)
	inject_at(&parts, 0, fp.root)
	joined, _ := filepath.join(parts[:], allocator)
	return joined
}

// picker_on_key navigates; Enter on a file sets fp.chosen and returns true
// for `picked`.
picker_on_key :: proc(fp: ^File_Picker, k: Key) -> (handled, picked: bool) {
	n := tree_selected(&fp.tree)
	if k.code == .Enter && n != nil && !n.branch {
		delete(fp.chosen)
		fp.chosen = strings.clone(picker_path(fp, n))
		return true, true
	}
	return tree_on_key(&fp.tree, k), false
}

picker_draw :: proc(f: ^Frame, r: Rect, fp: ^File_Picker, focused := true, tone: Tone = .Primary) {
	tree_draw(f, r, &fp.tree, focused, tone)
}
