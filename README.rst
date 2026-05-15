clnup
=====

A small Zig command-line tool that deletes (or dry-run lists) files and directories matched by rules
in a ``.clnup`` file — similar in spirit to ``.gitignore``, but for cleanup instead of exclusion.

Requires **Zig 0.16**.

Usage
-----

.. code-block:: text

    clnup [-r] [-f <file>] [-q] [-v] [-d] [path]

    Options:
      -r         Recurse into subdirectories
      -f FILE    Specify rules file (default: .clnup)
      -q         Quiet — suppress normal output
      -v         Verbose — print extra logging
      -d         Dry run — print matches, delete nothing

``path`` defaults to ``.`` (current directory).

Rules file
----------

Each line of ``.clnup`` is a pattern. Blank lines and lines starting with ``#`` are ignored.
Rules are evaluated in order; the last matching rule wins (same semantics as ``.gitignore``).

.. list-table::
   :widths: 20 80
   :header-rows: 1

   * - Syntax
     - Meaning
   * - ``*.o``
     - Match any file or directory named ``*.o`` at any depth (non-anchored)
   * - ``/build``
     - Match only at the top level of the target path (anchored with leading ``/``)
   * - ``target/``
     - Match directories only (trailing ``/``)
   * - ``!important.o``
     - Negate — keep this entry even if an earlier rule would delete it
   * - ``**``
     - Not supported; use ``-r`` for recursive traversal

Glob patterns support ``*`` (any sequence of characters) and ``?`` (any single character).

Example ``.clnup``::

    # Build artefacts
    *.o
    *.a
    /build/

    # Keep one specific object file
    !main.o

    # Scratch directories only, not files
    scratch/
    tmp/

Building
--------

.. code-block:: sh

    zig build-exe clnup.zig -O ReleaseSafe

Examples
--------

Dry-run, show what would be deleted recursively::

    clnup -r -d

Delete matched files in ``./dist``, quiet::

    clnup -q dist

Use a custom rules file::

    clnup -f .myclnup -r

Implementation notes
--------------------

- Rule matching uses a hand-rolled ``fnmatch`` supporting ``*`` and ``?``.
- Non-anchored rules are tested against every path-component suffix so ``*.o`` matches
  ``a/b/foo.o`` in recursive mode.
- Anchored rules (leading ``/``) are matched against the full relative path from the root.
- Directory-only rules (trailing ``/``) are skipped for non-directory entries.
- Symlinks are treated as directories for rule evaluation and recursion purposes.
- When a matched directory is deleted the walk does not descend into it.


License
-------
MIT
