#!/usr/bin/env python3
"""Gives Beef source the engine's one coding style.

    python3 tools/format/format_code.py            # every engine, editor, launcher and player source file
    python3 tools/format/format_code.py FILE...    # just these
    python3 tools/format/format_code.py --check    # list files that are not formatted; changes nothing

Steps, in order: one statement to a line (line breaks only); chains such as `for (..) if (..) x;` written out
with braces; a control statement's body on a line of its own, except short guards (`if (x) return;`); the Beef IDE's own formatter (Format Document) for indentation and spacing, run once for each
platform so that code under every #if is reached; braces round a control statement whose body is another one;
a blank line between the members of a type. String
literals are put back exactly as they were (the IDE formatter re-indents multi-line strings), and a file is
left alone if anything other than whitespace (or the braces added for chains) would change.

Needs BeefBuild on PATH; the formatter (tools/format/BfFmt) is built the first time it is needed.
"""
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
BFFMT = os.path.join(HERE, 'BfFmt', 'build', 'Debug_Linux64', 'BfFmt', 'BfFmt')
FOLDERS = ['Engine/src', 'Editor/src', 'Launcher/src', 'Player/src']
# Generated from bgfx's own definitions: kept as bgfx writes it.
SKIP = {'Engine/src/Platform/bgfx.bf'}
PLATFORMS = ['BF_PLATFORM_LINUX,BF_64_BIT,DEBUG', 'BF_PLATFORM_WINDOWS,BF_64_BIT', 'BF_PLATFORM_WASM', 'BF_PLATFORM_MACOS,BF_64_BIT']


# ---- finding string literals and comments ----

def literal_spans(src):
    spans = []; i = 0; n = len(src)
    while i < n:
        c = src[i]
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i + 2); i = n if j < 0 else j + 2; continue
        start = i
        k = i
        while k < n and src[k] in '$@': k += 1
        if k < n and src.startswith('"""', k):
            j = src.find('"""', k + 3); spans.append((start, j + 3)); i = j + 3; continue
        if k < n and src[k] == '"' and '@' in src[start:k]:
            j = k + 1
            while j < n:
                if src[j] == '"':
                    if j + 1 < n and src[j + 1] == '"': j += 2; continue
                    break
                j += 1
            spans.append((start, j + 1)); i = j + 1; continue
        if k < n and (src[k] == '"' or (src[k] == "'" and k == start)):
            q = src[k]; j = k + 1
            while j < n and src[j] != q:
                if src[j] == '\\': j += 1
                j += 1
            spans.append((start, j + 1)); i = j + 1; continue
        i = k + 1 if k > i else i + 1
    return spans

PLATFORMS = ['BF_PLATFORM_LINUX,BF_64_BIT,DEBUG', 'BF_PLATFORM_WINDOWS,BF_64_BIT', 'BF_PLATFORM_WASM', 'BF_PLATFORM_MACOS,BF_64_BIT']


def code_mask(src):
    mask = [True] * len(src)
    for s, e in literal_spans(src):
        for i in range(s, e): mask[i] = False
    i = 0; n = len(src)
    while i < n:
        if mask[i] and src.startswith('//', i):
            j = src.find('\n', i); j = n if j < 0 else j
            for k in range(i, j): mask[k] = False
            i = j; continue
        if mask[i] and src.startswith('/*', i):
            j = src.find('*/', i + 2); j = n if j < 0 else j + 2
            for k in range(i, j): mask[k] = False
            i = j; continue
        i += 1
    return mask

BLOCK_BEFORE = re.compile(r'(\)|\belse|\bdefer|\bdo|\btry|=>|\bget|\bset|\bfinally|^)\s*$')
KEEP_PROPERTY = re.compile(r'^\{\s*(get|set|private set|protected set|public get)\s*;')

def split_line(line, mask, base):
    """Returns the positions in `line` (relative) where a line break goes."""
    stripped = line.lstrip()
    if stripped.startswith('#'): return []
    code_end = len(line.rstrip('\n'))
    # last code character on the line
    last = -1
    for i in range(code_end):
        if mask[base + i] and not line[i].isspace(): last = i
    if last < 0: return []
    breaks = set()
    # matching braces on this line
    stack = []; pairs = {}
    paren = 0
    for i in range(code_end):
        if not mask[base + i]: continue
        c = line[i]
        if c in '([': paren += 1
        elif c in ')]': paren -= 1
        elif c == '{': stack.append((i, paren))
        elif c == '}':
            if stack: o, _ = stack.pop(); pairs[o] = i
    def has_semicolon(a, b):
        depth = 0
        for k in range(a + 1, b):
            if not mask[base + k]: continue
            if line[k] in '([{': depth += 1
            elif line[k] in ')]}': depth -= 1
            elif line[k] == ';' and depth == 0: return True
        return False
    blocks = []
    for o, c in pairs.items():
        before = line[:o]
        if KEEP_PROPERTY.match(line[o:]) : continue
        if BLOCK_BEFORE.search(before) and has_semicolon(o, c):
            blocks.append((o, c))
    # a statement block opened at the end of the line (K&R): move the brace down
    if line[last] == '{' and last not in pairs and line[:last].strip() and BLOCK_BEFORE.search(line[:last]) and not line[:last].rstrip().endswith('=>'):
        breaks.add(last)
    for o, c in blocks:
        if line[:o].strip(): breaks.add(o)
        breaks.add(o + 1)
        breaks.add(c)
        if c < last: breaks.add(c + 1)
    # semicolons that end a statement with more code after them
    depth = 0
    for i in range(code_end):
        if not mask[base + i]: continue
        ch = line[i]
        if ch in '([': depth += 1
        elif ch in ')]': depth -= 1
        elif ch == ';' and depth == 0 and i < last:
            # inside a kept property block, or an unexpanded brace on this line? only split at the level of
            # expanded blocks or the line itself
            enclosing = [p for p in pairs.items() if p[0] < i < p[1]]
            if all(p in blocks for p in enclosing):
                breaks.add(i + 1)
    # a case label whose statements were split: the statements go under it
    if breaks:
        m = re.match(r'\s*(case\b[^:]*|default):', line)
        if m and mask[base + m.end() - 1] and '?' not in line[:m.end()]:
            breaks.add(m.end())
    return sorted(b for b in breaks if 0 < b <= last)

def split_statements(src):
    mask = code_mask(src)
    out = []; base = 0
    for line in src.splitlines(keepends=True):
        if all(not mask[base + i] or line[i].isspace() for i in range(len(line))):
            out.append(line); base += len(line); continue
        cuts = split_line(line, mask, base)
        if cuts:
            indent = line[:len(line) - len(line.lstrip())]
            pieces = []; prev = 0
            for c in cuts:
                pieces.append(line[prev:c]); prev = c
            pieces.append(line[prev:])
            pieces = [p.strip(' \t') if k else p.rstrip(' \t') for k, p in enumerate(pieces)]
            nl = '\n' if line.endswith('\n') else ''
            text = pieces[0].rstrip('\n')
            for p in pieces[1:]:
                p = p.rstrip('\n')
                if p: text += '\n' + indent + p
            out.append(text + nl)
        else:
            out.append(line)
        base += len(line)
    return ''.join(out)



# ---- written-out chains ----

KW = re.compile(r'(if|for|while)\s*\(')

def headers(line, mask, base):
    """Split a line into control headers followed by the rest. Returns (headers, rest) or None."""
    i = len(line) - len(line.lstrip('\t ')); hs = []
    while True:
        m = KW.match(line, i)
        if not m or not mask[base + i]: break
        j = m.end(); depth = 1
        while j < len(line) and depth:
            if mask[base + j]:
                if line[j] == '(': depth += 1
                elif line[j] == ')': depth -= 1
            j += 1
        if depth: return None
        hs.append(line[i:j].strip()); i = j
        while i < len(line) and line[i] == ' ': i += 1
    if len(hs) < 2: return None
    return hs, line[i:].rstrip('\n')

def block_end(lines, start, masks, bases):
    """Line index of the brace closing the block that opens on lines[start] (a line that is just '{')."""
    depth = 0
    for k in range(start, len(lines)):
        for c_i, ch in enumerate(lines[k]):
            if not masks[bases[k] + c_i]: continue
            if ch == '{': depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0: return k
    return None

def unchain(src):
    mask = code_mask(src)
    lines = src.split('\n'); bases = []; b = 0
    for l in lines: bases.append(b); b += len(l) + 1
    out = []; closers = {}  # line index -> number of extra closing braces after it
    i = 0
    while i < len(lines):
        line = lines[i]
        r = headers(line, mask, bases[i])
        if r is None or line.lstrip().startswith('#'):
            out.append(line)
            for _ in range(closers.pop(i, 0)): out.append('}')
            i += 1; continue
        hs, rest = r
        indent = line[:len(line) - len(line.lstrip('\t '))]
        for h in hs[:-1]:
            out.append(indent + h); out.append(indent + '{')
        out.append(indent + hs[-1])
        n = len(hs) - 1
        if rest.strip() == '' :
            # the innermost header's block follows
            if i + 1 < len(lines) and lines[i + 1].strip() == '{':
                end = block_end(lines, i + 1, mask, bases)
                closers[end] = closers.get(end, 0) + n
            else:
                closers[i + 1] = closers.get(i + 1, 0) + n
        else:
            out.append(indent + '\t' + rest.strip())
            for _ in range(n): out.append(indent + '}')
        for _ in range(closers.pop(i, 0)): out.append('}')
        i += 1
    return '\n'.join(out)



JUMP = re.compile(r'(return|continue|break)\b')


def header_end(line, mask, base):
    """Where the control header (`if (..)`, `else if (..)`, `for (..)`, `while (..)`, `else`) starting a line ends,
    or None."""
    i = len(line) - len(line.lstrip('\t '))
    if base + i >= len(mask) or not mask[base + i]:
        return None
    other = re.match(r'else\b\s*', line[i:])
    if other:
        i += other.end()
        if not KW.match(line, i):
            return i
    m = KW.match(line, i)
    if not m:
        return None
    j = m.end()
    depth = 1
    while j < len(line) and depth:
        if mask[base + j]:
            if line[j] == '(':
                depth += 1
            elif line[j] == ')':
                depth -= 1
        j += 1
    return None if depth else j


def split_bodies(src):
    """A control statement's body on a line of its own, `if (a) b();` becoming two lines. Short guards that only
    leave (`if (x) return;`, `continue`, `break`) stay on one line."""
    mask = code_mask(src)
    out = []
    base = 0
    for line in src.split('\n'):
        end = header_end(line, mask, base) if line.strip() and not line.lstrip().startswith('#') else None
        rest = line[end:].strip() if end is not None else ''
        if rest and not rest.startswith(('{', '//', ';')) and not JUMP.match(rest) and mask[base + end + (len(line[end:]) - len(line[end:].lstrip()))]:
            indent = line[:len(line) - len(line.lstrip('\t '))]
            out.append(line[:end].rstrip())
            out.append(indent + '\t' + rest)
        else:
            out.append(line)
        base += len(line) + 1
    return '\n'.join(out)


# ---- the IDE formatter ----

def ensure_formatter():
    if not os.path.exists(BFFMT):
        print('Building the formatter (tools/format/BfFmt)...')
        subprocess.run([os.environ.get('BEEFBUILD', 'BeefBuild'), '-workspace=' + os.path.join(HERE, 'BfFmt'), '-config=Debug'], check=True)


def ide_format(src, tmp):
    work = os.path.join(tmp, 'file.bf')
    with open(work, 'w', encoding='utf-8') as f:
        f.write(src)
    for defines in PLATFORMS:
        subprocess.run([BFFMT, '--defines=' + defines, work], stdout=subprocess.DEVNULL)
    formatted = open(work, encoding='utf-8').read()
    # Put every string literal back as it was.
    a, b = literal_spans(src), literal_spans(formatted)
    if len(a) != len(b):
        return src
    out = []
    last = 0
    for (fs, fe), (os_, oe) in zip(b, a):
        out.append(formatted[last:fs])
        out.append(src[os_:oe])
        last = fe
    out.append(formatted[last:])
    return ''.join(out)


# ---- braces round nested control statements ----

CONTROL = re.compile(r'(if|for|while|else|using)\b')


def indent_of(line):
    return len(line) - len(line.lstrip('\t'))


def brace_nested(src):
    """Braces round a control statement's body when that body is itself a control statement on lines of its own
    (`for (..)` / `if (..)` / `x;` becomes `for (..) { if (..) x; }`). Runs on formatted text: the formatter indents
    by how the code parses, so following the indentation cannot change what the code means."""
    mask = code_mask(src)
    lines = src.split('\n')
    starts = []
    at = 0
    for line in lines:
        starts.append(at)
        at += len(line) + 1
    def code(i):
        first = starts[i] + indent_of(lines[i])
        return first < len(mask) and mask[first]
    i = 0
    while i < len(lines) - 1:
        text = lines[i].strip()
        head = CONTROL.match(text) or text.startswith('else')
        if head and code(i) and not text.endswith(('{', ';')) and not text.startswith('switch'):
            depth = indent_of(lines[i])
            body = lines[i + 1]
            if body.strip() != '{' and indent_of(body) == depth + 1 and code(i + 1) and re.match(r'(if|for|while|using)\b', body.strip()):
                end = i + 1
                while end < len(lines) and (lines[end].strip() == '' or indent_of(lines[end]) > depth):
                    end += 1
                while lines[end - 1].strip() == '':
                    end -= 1
                lines.insert(end, '\t' * depth + '}')
                lines.insert(i + 1, '\t' * depth + '{')
                # Positions moved: work them out again.
                return brace_nested('\n'.join(lines))
        i += 1
    return src


# ---- blank lines between members ----

def blank_lines(src):
    """One blank line after the `using` lines and after `namespace X;`, and between the members of a type."""
    if not re.search(r'^namespace [\w.]+;', src, re.M):
        return src
    out = []
    in_string = False
    for line in src.split('\n'):
        if out and line.strip() and not in_string:
            last = out[-1]
            if (last.startswith('using ') and not line.startswith('using ')) or re.match(r'namespace [\w.]+;', last):
                out.append('')
        if out and out[-1] == '\t}' and re.match(r'\t[^\t}\s]', line) and not in_string:
            if not re.match(r'\t(else|while|catch|finally)\b', line):
                out.append('')
        out.append(line)
        if line.count('\"\"\"') % 2 == 1:
            in_string = not in_string
    return '\n'.join(out)


# ---- all of it ----

def squash(text, braces=False):
    return re.sub(r'\s|[{}]' if braces else r'\s', '', text)


def literals(text):
    return [text[s:e] for s, e in literal_spans(text)]


def split_fully(src):
    # Breaking up a line can leave a block whose own statements are split on the next pass.
    for _ in range(4):
        nxt = split_statements(src)
        if nxt == src:
            break
        src = nxt
    return src


def format_source(src, tmp):
    """The formatted text, or None when a step would have changed more than it may."""
    result = src
    for step, braces in ((split_fully, False), (unchain, True), (split_bodies, False), (lambda s: ide_format(s, tmp), False), (brace_nested, True), (blank_lines, False)):
        nxt = step(result)
        if squash(nxt, braces) != squash(result, braces) or literals(nxt) != literals(result):
            return None
        result = nxt
    return result


def source_files():
    for folder in FOLDERS:
        for base, dirs, files in os.walk(os.path.join(ROOT, folder)):
            dirs[:] = [d for d in dirs if d != 'build']
            for name in sorted(files):
                path = os.path.join(base, name)
                if name.endswith('.bf') and os.path.relpath(path, ROOT) not in SKIP:
                    yield path


def main(args):
    check = '--check' in args
    paths = [a for a in args if a != '--check'] or list(source_files())
    ensure_formatter()
    changed = refused = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path in paths:
            src = open(path, encoding='utf-8').read()
            result = format_source(src, tmp)
            rel = os.path.relpath(path, ROOT)
            if result is None:
                print('left alone (formatting would change more than whitespace):', rel)
                refused += 1
            elif result != src:
                changed += 1
                if check:
                    print('not formatted:', rel)
                else:
                    with open(path, 'w', encoding='utf-8') as f:
                        f.write(result)
                    print('formatted', rel)
    if check:
        print(f'{changed} file(s) need formatting.')
        return 1 if changed or refused else 0
    return 1 if refused else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
