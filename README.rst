clnup
=====

``clnup`` is a directory cleanup tool written in `Zig <https://ziglang.org/>`_.
It applies user-defined cleanup rules from a ``.clnup`` file, optionally recursively traversing directories.
It can print, delete, or touch files matching the provided patterns.

Features
--------

- Reads glob-style cleanup rules from a config file (default: ``.clnup``).
- Works recursively or non-recursively, depending on flags.
- Provides quiet and verbose output control.
- Simple built-in ``fnmatch`` implementation for pattern matching.
- Safe by default—no destructive action without explicit flags.

Usage
-----

.. code-block:: bash

   clnup [options] [path]

The optional *path* argument defaults to the current directory (``.``).

Options
-------

- ``-r``
  Recurse into subdirectories. By default, only the top level is processed.

- ``-f <path>``
  Specify the location of the rules file. Defaults to ``.clnup`` in the current directory.
  You can also use a global rules file, e.g. ``-f $HOME/.clnup``.

- ``-a <action>``
  Perform an action:
  - ``print`` — display paths matched by rules (default if dry-run).
  - ``delete`` — remove files matching rules.
  - ``touch`` — ensure files exist (creates missing ones).

- ``-q``
  Quiet mode. Suppresses non-error output.

- ``-v``
  Verbose mode. Prints diagnostic details about rule evaluation and matched files.

- ``--dry-run``
  Print matches but perform no modification (alias for ``-a print``).

Examples
--------

.. code-block:: bash

   # Print matched files (dry-run)
   clnup -r

   # Delete recursively using project local config
   clnup -r -a delete

   # Use global rules file from home directory
   clnup -r -f $HOME/.clnup

   # Verbose recursive run on custom directory
   clnup -r -v ../build/tmp/a/b

   # Quiet cleanup on current working directory
   clnup -q -a delete

The .clnup Specification
------------------------

Each line in the ``.clnup`` file defines one rule.

Syntax
~~~~~~

.. code-block::

   [!] [/]<pattern>[/]

Meaning:

- ``!`` — Negate a rule (keep instead of delete).
- ``/`` — Anchor pattern to the top directory.
- Trailing ``/`` — Apply to directories only.
- Lines starting with ``#`` — Comments (ignored).
- Blank lines are ignored.

Matching semantics:

- ``*`` — matches zero or more characters.
- ``?`` — matches exactly one character.
- Rules are applied in order; the **last matching rule wins**.

Example
~~~~~~~

.. code-block:: text

   # Delete all build directories
   build/

   # Delete all log files
   *.log

   # But keep this cache
   !/build/cache/

   # Ignore editor swap files
   *~


Verbose Example
---------------

When running in verbose mode (``-v``), ``clnup`` prints details about rule evaluation:

.. code-block:: text

   [match] build/  (rule: "build/")
   [skip]  build/cache/  (rule: "!/build/cache/")

This helps verify which rule matched a file before applying destructive actions.


Quiet Mode
----------

When ``-q`` is used, only errors are printed — ideal for automated scripts.

Example:

.. code-block:: bash

   clnup -r -q -a delete


Building
--------

.. code-block:: bash

   zig build-exe clnup.zig -O ReleaseSafe

   # or
   zig run clnup.zig -- -r -a print


License
-------

MIT License (or your chosen license).
No external dependencies.
