# Shell Style Guide — Checklist

Authored, revised and maintained by many Googlers.

A checklist form of the Google Shell Style Guide. Each item restates one rule.
The notes under an item give the reason from the guide. The code blocks give the
examples from the guide.

Source: <https://google.github.io/styleguide/shellguide.html>

## Table of Contents

| Section                                                                              | Contents                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Background](#s1-background)                                                         | [Which Shell to Use](#s1.1-which-shell-to-use) - [When to use Shell](#s1.2-when-to-use-shell)                                                                                                                                                                                                                                                                                                             |
| [Shell Files and Interpreter Invocation](#s2-shell-files-and-interpreter-invocation) | [File Extensions](#s2.1-file-extensions) - [SUID/SGID](#s2.2-suid-sgid)                                                                                                                                                                                                                                                                                                                                   |
| [Environment](#s3-environment)                                                       | [STDOUT vs STDERR](#s3.1-stdout-vs-stderr)                                                                                                                                                                                                                                                                                                                                                                |
| [Comments](#s4-comments)                                                             | [File Header](#s4.1-file-header) - [Function Comments](#s4.2-function-comments) - [Implementation Comments](#s4.3-implementation-comments) - [TODO Comments](#s4.4-todo-comments)                                                                                                                                                                                                                         |
| [Formatting](#s5-formatting)                                                         | [Indentation](#s5.1-indentation) - [Line Length and Long Strings](#s5.2-line-length-and-long-strings) - [Pipelines](#s5.3-pipelines) - [Control Flow](#s5.4-control-flow) - [Case statement](#s5.5-case-statement) - [Variable expansion](#s5.6-variable-expansion) - [Quoting](#s5.7-quoting)                                                                                                            |
| [Features and Bugs](#s6-features-and-bugs)                                           | [ShellCheck](#s6.1-shellcheck) - [Command Substitution](#s6.2-command-substitution) - [Test, `[… ]`, and `[[… ]]`](#s6.3-tests) - [Testing Strings](#s6.4-testing-strings) - [Wildcard Expansion of Filenames](#s6.5-wildcard-expansion-of-filenames) - [Eval](#s6.6-eval) - [Arrays](#s6.7-arrays) - [Pipes to While](#s6.8-pipes-to-while) - [Arithmetic](#s6.9-arithmetic) - [Aliases](#s6.10-aliases) |
| [Naming Conventions](#s7-naming-conventions)                                         | [Function Names](#s7.1-function-names) - [Variable Names](#s7.2-variable-names) - [Constants and Environment Variable Names](#s7.3-constants-and-environment-variable-names) - [Source Filenames](#s7.4-source-filenames) - [Use Local Variables](#s7.5-use-local-variables) - [Function Location](#s7.6-function-location) - [main](#s7.7-main)                                                          |
| [Calling Commands](#s8-calling-commands)                                             | [Checking Return Values](#s8.1-checking-return-values) - [Builtin Commands vs. External Commands](#s8.2-builtin-commands-vs-external-commands)                                                                                                                                                                                                                                                            |
| [When in Doubt: Be Consistent](#s9-conclusion)                                       |                                                                                                                                                                                                                                                                                                                                                                                                           |

<a id="s1-background"></a>

## Background

Shell scripting is not a development language, but it is used for utility
scripts throughout Google. This guide recognizes that use; it does not suggest
shell for widespread deployment.

<a id="s1.1-which-shell-to-use"></a>

### Which Shell to Use

- [ ] Use Bash as the only shell scripting language for executables.
- [ ] Start an executable with `#!/bin/bash` and minimal flags.
- [ ] Use `set` to set shell options, so that a call as `bash script_name` does
      not break the script.
- [ ] Do not strive for POSIX compatibility and do not avoid "bashisms".
  - Bash on all machines gives one consistent shell language.
- [ ] Use plain Bourne shell only when the target forces it.
  - Example: a legacy operating system or a constrained execution environment
    requires Bourne shell for some scripts.

<a id="s1.2-when-to-use-shell"></a>

### When to use Shell

- [ ] Use shell only for small utilities or simple wrapper scripts.
- [ ] Choose shell when the script mostly calls other utilities and does little
      data manipulation.
- [ ] Do not choose shell when performance matters.
- [ ] Rewrite the script in a more structured language _now_ when it is more
      than 100 lines long or uses non-straightforward control flow logic.
  - Scripts grow. An early rewrite costs less than a later rewrite.
- [ ] Judge the complexity of the code by whether other people can maintain it,
      not only its author.
  - Use this test when you decide whether to switch languages.
- [ ] For a migration from shell to a proper language, follow the
      [Deshell Playbook](https://github.com/google/deshell/blob/main/playbook.md).
  - It gives a robust approach for a smooth replacement of production code.

<a id="s2-shell-files-and-interpreter-invocation"></a>

## Shell Files and Interpreter Invocation

<a id="s2.1-file-extensions"></a>

### File Extensions

- [ ] Give an executable a `.sh` extension or no extension.
- [ ] Use a `.sh` extension when a build rule renames the source file.
  - Example: a source file `foo.sh` with a build rule named `foo`.
- [ ] Use no extension when the executable goes directly into the user's
      `PATH`.
  - The language of a program need not be known at run time.
  - Shell needs no extension, so no extension is preferred for an executable
    that a user invokes directly.
  - Consider deploying the output of a build rule, not the source file.
- [ ] Either choice is correct when neither case above applies.
- [ ] Give a library a `.sh` extension.
- [ ] Do not make a library executable.

<a id="s2.2-suid-sgid"></a>

### SUID/SGID

- [ ] Never set SUID or SGID on a shell script.
  - Shell has too many security issues. It is almost impossible to secure
    shell sufficiently for SUID/SGID.
  - Bash makes SUID difficult, but some platforms still permit it.
- [ ] Use `sudo` when you need elevated access.

<a id="s3-environment"></a>

## Environment

<a id="s3.1-stdout-vs-stderr"></a>

### STDOUT vs STDERR

- [ ] Send every error message to `STDERR`.
  - This separates normal status from actual issues.
- [ ] Provide a function that prints error messages and other status
      information.

```shell
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

if ! do_something; then
  err "Unable to do_something"
  exit 1
fi
```

<a id="s4-comments"></a>

## Comments

<a id="s4.1-file-header"></a>

### File Header

- [ ] Start each file with a top-level comment that gives a brief overview of
      its contents.
- [ ] A copyright notice and author information are optional.

```shell
#!/bin/bash
#
# Perform hot backups of Oracle databases.
```

<a id="s4.2-function-comments"></a>

### Function Comments

- [ ] Add a function header comment to any function that is not both obvious
      and short.
- [ ] Add a function header comment to every function in a library, regardless
      of length or complexity.
- [ ] Make the comments sufficient for another person to use the program or a
      library function without reading the code (with self-help, if provided).
- [ ] Describe the intended API behaviour with these fields:
  - [ ] Description of the function.
  - [ ] Globals: global variables used and modified.
  - [ ] Arguments: arguments taken.
  - [ ] Outputs: output to STDOUT or STDERR.
  - [ ] Returns: values other than the default exit status of the last command
        run.

```shell
#######################################
# Cleanup files from the backup directory.
# Globals:
#   BACKUP_DIR
#   ORACLE_SID
# Arguments:
#   None
#######################################
function cleanup() {
  …
}

#######################################
# Get configuration directory.
# Globals:
#   SOMEDIR
# Arguments:
#   None
# Outputs:
#   Writes location to stdout
#######################################
function get_dir() {
  echo "${SOMEDIR}"
}

#######################################
# Delete a file in a sophisticated manner.
# Arguments:
#   File to delete, a path.
# Returns:
#   0 if thing was deleted, non-zero on error.
#######################################
function del_thing() {
  rm "$1"
}
```

<a id="s4.3-implementation-comments"></a>

### Implementation Comments

- [ ] Comment tricky, non-obvious, interesting, or important parts of the code.
- [ ] Do not comment everything.
- [ ] Put a short comment on a complex algorithm or on an unusual action.
  - This follows the general Google coding comment practice.

<a id="s4.4-todo-comments"></a>

### TODO Comments

- [ ] Use a TODO comment for code that is temporary, a short-term solution, or
      good-enough but not perfect.
  - This matches the convention in the
    [C++ Guide](https://google.github.io/styleguide/cppguide.html#TODO_Comments).
- [ ] Write the string `TODO` in all caps.
- [ ] After `TODO`, give the name, e-mail address, or other identifier of the
      person with the best context about the problem.
  - The consistent string is searchable, so a reader can request more details.
  - A `TODO` is not a commitment that the referenced person will fix the
    problem. Usually give your own name.

```shell
# TODO(mrmonkey): Handle the unlikely edge cases (bug ####)
```

<a id="s5-formatting"></a>

## Formatting

- [ ] Follow the style that is already in a file that you modify.
- [ ] Apply the rules below to all new code.

<a id="s5.1-indentation"></a>

### Indentation

- [ ] Indent with 2 spaces.
- [ ] Do not use tabs.
- [ ] Put blank lines between blocks, to improve readability.
- [ ] In an existing file, stay faithful to the existing indentation.
- [ ] Exception: tabs are permitted for the body of a `<<-` tab-indented
      [here-document](https://www.gnu.org/software/bash/manual/html_node/Redirections.html#Here-Documents).

<a id="s5.2-line-length-and-long-strings"></a>

### Line Length and Long Strings

- [ ] Keep each line at 80 characters or fewer.
- [ ] Write a literal string longer than 80 characters with a
      [here document](https://www.gnu.org/software/bash/manual/html_node/Redirections.html#Here-Documents)
      or an embedded newline, if possible.
- [ ] Keep a word longer than 80 characters that cannot sensibly be split on a
      line of its own, or factor it into a variable.
  - Examples: file paths and URLs.
  - String matching of such an item (for example, with `grep`) helps
    maintenance.

```shell
# DO use 'here document's
cat <<END
I am an exceptionally long
string.
END

# Embedded newlines are ok too
long_string="I am an exceptionally
long string."

long_file="/i/am/an/exceptionally/loooooooooooooooooooooooooooooooooooooooooooooooooooong_file"

long_string_with_long_file="i am including an exceptionally \
/very/long/file\
 in this long string."

# Long file converted into a shorter variable name with cleaner line breaking.
long_string_alt="i am an including an exceptionally ${long_file} in this long\
 string"
```

```shell
# Just because a line contains an exception doesn't mean the rest of the
# line shouldn't be wrapped like usual.

bad_long_string_with_long_file="i am including an exceptionally /very/long/file in this long string."
```

<a id="s5.3-pipelines"></a>

### Pipelines

- [ ] Put a pipeline on one line when it all fits on one line.
- [ ] Split a pipeline that does not fit into one pipe segment per line.
- [ ] Put the pipe on the newline and indent the next section of the pipe by 2
      spaces.
- [ ] Use `\ ` consistently to indicate line continuation.
- [ ] Apply these rules to a chain with `|` and to a logical compound with `||`
      and `&&`.

```shell
# All fits on one line
command1 | command2

# Long commands
command1 \
  | command2 \
  | command3 \
  | command4
```

- [ ] Put comments before the whole pipeline.
  - The split form helps a reader to tell a pipeline from a regular long
    command continuation, especially when a line uses both.
- [ ] Move the low-level details of a large, complex comment and pipeline into
      a helper function.

<a id="s5.4-control-flow"></a>

### Control Flow

Shell control flow differs a little, but these rules use the same principle as
the braces of a function declaration.

- [ ] Put `; then` and `; do` on the same line as the `if`, `for`, or `while`.
- [ ] Apply the same principle to `until` and `select`.
- [ ] Put `else` on its own line.
- [ ] Put the closing statements `fi` and `done` on their own lines, vertically
      aligned with the opening statement.

```shell
# If inside a function remember to declare the loop variable as
# a local to avoid it leaking into the global environment:
local dir
for dir in "${dirs_to_cleanup[@]}"; do
  if [[ -d "${dir}/${SESSION_ID}" ]]; then
    log_date "Cleaning up old files in ${dir}/${SESSION_ID}"
    rm "${dir}/${SESSION_ID}/"* || error_message
  else
    mkdir -p "${dir}/${SESSION_ID}" || error_message
  fi
done
```

- [ ] Include `in "$@"` in a for loop, for clarity, although Bash permits its
      [omission](https://www.gnu.org/software/bash/manual/html_node/Looping-Constructs.html#index-for).

```shell
for arg in "$@"; do
  echo "argument: ${arg}"
done
```

<a id="s5.5-case-statement"></a>

### Case statement

- [ ] Indent alternatives by 2 spaces.
- [ ] In a one-line alternative, put a space after the close parenthesis of the
      pattern and before the `;;`.
- [ ] Split a long or multi-command alternative over multiple lines, with the
      pattern, the actions, and `;;` on separate lines.
- [ ] Indent the matching expressions one level from the `case` and `esac`.
- [ ] Indent multiline actions by one more level.
- [ ] Do not quote a match expression; in general, no quoting is necessary.
- [ ] Do not put an open parenthesis before a pattern expression.
- [ ] Do not use the `;&` and `;;&` notations.

```shell
case "${expression}" in
  a)
    variable="…"
    some_command "${variable}" "${other_expr}" …
    ;;
  absolute)
    actions="relative"
    another_command "${actions}" "${other_expr}" …
    ;;
  *)
    error "Unexpected expression '${expression}'"
    ;;
esac
```

- [ ] You may put a simple command on the same line as the pattern _and_ `;;`
      when the expression stays readable.
  - This is often correct for single-letter option processing.
- [ ] When the actions do not fit on one line, put the pattern on its own line,
      then the actions, then `;;` on its own line.
- [ ] On one line, put a space after the close parenthesis of the pattern and
      another space before the `;;`.

```shell
verbose='false'
aflag=''
bflag=''
files=''
while getopts 'abf:v' flag; do
  case "${flag}" in
    a) aflag='true' ;;
    b) bflag='true' ;;
    f) files="${OPTARG}" ;;
    v) verbose='true' ;;
    *) error "Unexpected option ${flag}" ;;
  esac
done
```

<a id="s5.6-variable-expansion"></a>

### Variable expansion

Order of precedence: stay consistent with what you find; quote your variables;
prefer `"${var}"` over `"$var"`. These are strong recommendations, not
mandatory regulation, but do not take them lightly.

- [ ] Stay consistent with what you find in existing code.
- [ ] Quote variables.
- [ ] Do not brace-delimit a single-character shell special or positional
      parameter, unless this is strictly necessary or avoids deep confusion.
- [ ] Prefer brace-delimiting all other variables.

```shell
# Section of *recommended* cases.

# Preferred style for 'special' variables:
echo "Positional: $1" "$5" "$3"
echo "Specials: !=$!, -=$-, _=$_. ?=$?, #=$# *=$* @=$@ \$=$$ …"

# Braces necessary:
echo "many parameters: ${10}"

# Braces avoiding confusion:
# Output is "a0b0c0"
set -- a b c
echo "${1}0${2}0${3}0"

# Preferred style for other variables:
echo "PATH=${PATH}, PWD=${PWD}, mine=${some_var}"
while read -r f; do
  echo "file=${f}"
done < <(find /tmp)
```

```shell
# Section of *discouraged* cases

# Unquoted vars, unbraced vars, brace-delimited single letter
# shell specials.
echo a=$avar "b=$bvar" "PID=${$}" "${1}"

# Confusing use: this is expanded as "${1}0${2}0${3}0",
# not "${10}${20}${30}
set -- a b c
echo "$10$20$30"
```

- [ ] Remember that braces in `${var}` are _not_ a form of quoting. Use double
      quotes _as well_.

<a id="s5.7-quoting"></a>

### Quoting

- [ ] Always quote a string that contains a variable, a command substitution, a
      space, or a shell metacharacter.
  - Exception: a careful unquoted expansion is required, or the value is a
    shell-internal integer (see the next items).
- [ ] Use arrays for safe quoting of a list of elements, especially
      command-line flags. See [Arrays](#arrays) below.
- [ ] Optionally quote the shell-internal, readonly
      [special variables](https://www.gnu.org/software/bash/manual/html_node/Special-Parameters.html)
      that are defined to be integers: `$?`, `$#`, `$$`, `$!`.
- [ ] Prefer to quote the "named" internal integer variables, for example
      `PPID`, for consistency.
- [ ] Prefer to quote strings that are "words", as opposed to command options
      or path names.
- [ ] Follow the quoting rules for pattern matches in `[[ … ]]`. See the
      [Test, `[ … ]`, and `[[ … ]]`](#tests) section below.
- [ ] Use `"$@"`, not `$*`, unless you have a specific reason for `$*`.
  - An acceptable reason: append the arguments to a string in a message or a
    log.

```shell
# 'Single' quotes indicate that no substitution is desired.
# "Double" quotes indicate that substitution is required/tolerated.

# Simple examples

# "quote command substitutions"
# Note that quotes nested inside "$()" don't need escaping.
flag="$(some_command and its args "$@" 'quoted separately')"

# "quote variables"
echo "${flag}"

# Use arrays with quoted expansion for lists.
declare -a FLAGS
FLAGS=( --foo --bar='baz' )
readonly FLAGS
mybinary "${FLAGS[@]}"

# It's ok to not quote internal integer variables.
if (( $# > 3 )); then
  echo "ppid=${PPID}"
fi

# "never quote literal integers"
value=32
# "quote command substitutions", even when you expect integers
number="$(generate_number)"

# "prefer quoting words", not compulsory
readonly USE_INTEGER='true'

# "quote shell meta characters"
echo 'Hello stranger, and well met. Earn lots of $$$'
echo "Process $$: Done making \$\$\$."

# "command options or path names"
# ($1 is assumed to contain a value here)
grep -li Hugo /dev/null "$1"

# Less simple examples
# "quote variables, unless proven false": ccs might be empty
git send-email --to "${reviewers}" ${ccs:+"--cc" "${ccs}"}

# Positional parameter precautions: $1 might be unset
# Single quotes leave regex as-is.
grep -cP '([Ss]pecial|\|?characters*)$' ${1:+"$1"}

# For passing on arguments,
# "$@" is right almost every time, and
# $* is wrong almost every time:
#
# * $* and $@ will split on spaces, clobbering up arguments
#   that contain spaces and dropping empty strings;
# * "$@" will retain arguments as-is, so no args
#   provided will result in no args being passed on;
#   This is in most cases what you want to use for passing
#   on arguments.
# * "$*" expands to one argument, with all args joined
#   by (usually) spaces,
#   so no args provided will result in one empty string
#   being passed on.
#
# Consult
# https://www.gnu.org/software/bash/manual/html_node/Special-Parameters.html and
# https://mywiki.wooledge.org/BashGuide/Arrays for more

(set -- 1 "2 two" "3 three tres"; echo $#; set -- "$*"; echo "$#, $@")
(set -- 1 "2 two" "3 three tres"; echo $#; set -- "$@"; echo "$#, $@")
```

<a id="s6-features-and-bugs"></a>

## Features and Bugs

<a id="s6.1-shellcheck"></a>

### ShellCheck

- [ ] Run [ShellCheck](https://www.shellcheck.net/) on every script, large or
      small.
  - It identifies common bugs and warnings.

<a id="s6.2-command-substitution"></a>

### Command Substitution

- [ ] Use `$(command)` instead of backticks.
  - Nested backticks require `\ ` on the inner ones. The `$(command)` format
    does not change when nested and is easier to read.

```shell
# This is preferred:
var="$(command "$(command1)")"
```

```shell
# This is not:
var="`command \`command1\``"
```

<a id="s6.3-tests"></a>
<a id="tests"></a>

### Test, `[ … ]`, and `[[ … ]]`

- [ ] Prefer `[[ … ]]` to `[ … ]`, `test`, and `/usr/bin/[`.
  - `[[ … ]]` reduces errors: no pathname expansion or word splitting occurs
    between `[[` and `]]`.
  - `[[ … ]]` permits pattern and regular expression matching; `[ … ]` does
    not.

```shell
# This ensures the string on the left is made up of characters in
# the alnum character class followed by the string name.
# Note that the RHS should not be quoted here.
if [[ "filename" =~ ^[[:alnum:]]+name ]]; then
  echo "Match"
fi

# This matches the exact pattern "f*" (Does not match in this case)
if [[ "filename" == "f*" ]]; then
  echo "Match"
fi
```

```shell
# This gives a "too many arguments" error as f* is expanded to the
# contents of the current directory. It might also trigger the
# "unexpected operator" error because `[` does not support `==`, only `=`.
if [ "filename" == f* ]; then
  echo "Match"
fi
```

- [ ] Read E14 in the [Bash FAQ](https://tiswww.case.edu/php/chet/bash/FAQ) for
      the details.

<a id="s6.4-testing-strings"></a>

### Testing Strings

- [ ] Use quotes, not filler characters, where possible.
- [ ] Test for an empty or non-empty string, or compare with an empty string,
      instead of using filler characters.
  - Bash handles an empty string in a test, and such a test is easier to read.

```shell
# Do this:
if [[ "${my_var}" == "some_string" ]]; then
  do_something
fi

# -z (string length is zero) and -n (string length is not zero) are
# preferred over testing for an empty string
if [[ -z "${my_var}" ]]; then
  do_something
fi

# This is OK (ensure quotes on the empty side), but not preferred:
if [[ "${my_var}" == "" ]]; then
  do_something
fi
```

```shell
# Not this:
if [[ "${my_var}X" == "some_stringX" ]]; then
  do_something
fi
```

- [ ] Use `-z` or `-n` explicitly, to avoid confusion about what you test for.

```shell
# Use this
if [[ -n "${my_var}" ]]; then
  do_something
fi
```

```shell
# Instead of this
if [[ "${my_var}" ]]; then
  do_something
fi
```

- [ ] Use `==` for equality, not `=`, although both work.
  - `==` encourages the use of `[[`; `=` can be confused with an assignment.
- [ ] Do not use `<` and `>` in `[[ … ]]`; they perform a lexicographical
      comparison.
- [ ] Use `(( … ))`, `-lt`, or `-gt` for a numerical comparison.

```shell
# Use this
if [[ "${my_var}" == "val" ]]; then
  do_something
fi

if (( my_var > 3 )); then
  do_something
fi

if [[ "${my_var}" -gt 3 ]]; then
  do_something
fi
```

```shell
# Instead of this
if [[ "${my_var}" = "val" ]]; then
  do_something
fi

# Probably unintended lexicographical comparison.
if [[ "${my_var}" > 3 ]]; then
  # True for 4, false for 22.
  do_something
fi
```

<a id="s6.5-wildcard-expansion-of-filenames"></a>

### Wildcard Expansion of Filenames

- [ ] Use an explicit path when you do a wildcard expansion of filenames.
- [ ] Expand with `./*`, not `*`, because a filename can begin with a `-`.

```shell
# Here's the contents of the directory:
# -f  -r  somedir  somefile

# Incorrectly deletes almost everything in the directory by force
psa@bilby$ rm -v *
removed directory: `somedir'
removed `somefile'
```

```shell
# As opposed to:
psa@bilby$ rm -v ./*
removed `./-f'
removed `./-r'
rm: cannot remove `./somedir': Is a directory
removed `./somefile'
```

<a id="s6.6-eval"></a>

### Eval

- [ ] Avoid `eval`.
  - Eval changes the input when you assign to variables.
  - Eval can set variables without a check of what those variables were.

```shell
# What does this set?
# Did it succeed? In part or whole?
eval $(set_my_variables)

# What happens if one of the returned values has a space in it?
variable="$(eval some_function)"
```

<a id="s6.7-arrays"></a>

### Arrays

- [ ] Use a Bash array to store a list of elements and to avoid quoting
      complications, especially for an argument list.
- [ ] Do not use an array to facilitate a more complex data structure. See
      [When to use Shell](#when-to-use-shell) above.
- [ ] Expand an array into individual elements for a command or a loop.
  - An array stores an ordered collection of strings.
- [ ] Do not use a single string for multiple command arguments.
  - It leads to `eval` or to nested quotes inside the string.
  - That does not give a reliable or readable result and adds needless
    complexity.

```shell
# An array is assigned using parentheses, and can be appended to
# with +=( … ).
declare -a flags
flags=(--foo --bar='baz')
flags+=(--greeting="Hello ${name}")
mybinary "${flags[@]}"
```

```shell
# Don’t use strings for sequences.
flags='--foo --bar=baz'
flags+=' --greeting="Hello world"'  # This won’t work as intended.
mybinary ${flags}
```

```shell
# Command expansions return single strings, not arrays. Avoid
# unquoted expansion in array assignments because it won’t
# work correctly if the command output contains special
# characters or whitespace.

# This expands the listing output into a string, then does special keyword
# expansion, and then whitespace splitting.  Only then is it turned into a
# list of words.  The ls command may also change behavior based on the user's
# active environment!
declare -a files=($(ls /directory))

# The get_arguments writes everything to STDOUT, but then goes through the
# same expansion process above before turning into a list of arguments.
mybinary $(get_arguments)
```

<a id="s6.7.1-arrays-pros"></a>

#### Arrays Pros

- An array gives a list without confusing quoting semantics. Without an array,
  authors try to nest quotes inside a string.
- An array stores a sequence or list of arbitrary strings safely, including
  strings that contain whitespace.

<a id="s6.7.2-arrays-cons"></a>

#### Arrays Cons

- An array can make the complexity of a script grow.

<a id="s6.7.3-arrays-decision"></a>

#### Arrays Decision

- [ ] Use an array to create and pass a list safely.
- [ ] Use an array for a set of command arguments, to avoid confusing quoting
      issues.
- [ ] Access an array with quoted expansion: `"${array[@]}"`.
- [ ] Do not use shell scripting at all when you need more advanced data
      manipulation. See [above](#when-to-use-shell).

<a id="s6.8-pipes-to-while"></a>

### Pipes to While

- [ ] Prefer a process substitution or the `readarray` builtin (bash4+) to a
      pipe to `while`.
  - A pipe creates a subshell. A variable changed in a pipeline does not
    propagate to the parent shell.
  - The implicit subshell in a pipe to `while` can cause subtle bugs that are
    hard to track down.

```shell
last_line='NULL'
your_command | while read -r line; do
  if [[ -n "${line}" ]]; then
    last_line="${line}"
  fi
done

# This will always output 'NULL'!
echo "${last_line}"
```

- [ ] Use a process substitution to redirect from a subshell into `while`
      without putting the `while` (or another command) in a subshell.
  - A process substitution also creates a subshell, but it has this advantage.

```shell
last_line='NULL'
while read line; do
  if [[ -n "${line}" ]]; then
    last_line="${line}"
  fi
done < <(your_command)

# This will output the last non-empty line from your_command
echo "${last_line}"
```

- [ ] Alternatively, use the `readarray` builtin to read the file into an
      array, then loop over the contents of the array.
  - Use a process substitution with `readarray`, not a pipe, for the same
    reason as above.
  - Advantage: the input generation for the loop is before the loop, not after
    it.

```shell
last_line='NULL'
readarray -t lines < <(your_command)
for line in "${lines[@]}"; do
  if [[ -n "${line}" ]]; then
    last_line="${line}"
  fi
done
echo "${last_line}"
```

- [ ] Be cautious with a for-loop over output, as in `for var in $(...)`.
  - The output splits on whitespace, not on line.
  - Sometimes you know the output has no unexpected whitespace.
  - When this is not obvious or the form does not improve readability (for
    example, a long command inside `$(...)`), a `while read` loop or
    `readarray` is often safer and clearer.

<a id="s6.9-arithmetic"></a>

### Arithmetic

- [ ] Use `(( … ))` or `$(( … ))`.
- [ ] Do not use `let`.
- [ ] Do not use `$[ … ]`.
- [ ] Do not use `expr`.
- [ ] Do not use `[[ … ]]` for a numeric comparison.
  - `<` and `>` in `[[ … ]]` perform a lexicographical comparison. See
    [Testing Strings](#testing-strings).
- [ ] Avoid `(( … ))` as a standalone statement.
- [ ] Be wary when the expression of `(( … ))` evaluates to zero, particularly
      with `set -e`.
  - Example: `set -e; i=0; (( i++ ))` exits the shell.

```shell
# Simple calculation used as text - note the use of $(( … )) within
# a string.
echo "$(( 2 + 2 )) is 4"

# When performing arithmetic comparisons for testing
if (( a < b )); then
  …
fi

# Some calculation assigned to a variable.
(( i = 10 * j + 400 ))
```

```shell
# This form is non-portable and deprecated
i=$[2 * 10]

# Despite appearances, 'let' isn't one of the declarative keywords,
# so unquoted assignments are subject to globbing wordsplitting.
# For the sake of simplicity, avoid 'let' and use (( … ))
let i="2 + 2"

# The expr utility is an external program and not a shell builtin.
i=$( expr 4 + 4 )

# Quoting can be error prone when using expr too.
i=$( expr 4 '*' 4 )
```

- [ ] Be aware that the built-in arithmetic of the shell is many times faster
      than `expr`.
- [ ] Inside `$(( … ))`, write `var`, not `${var}` or `$var`, for cleaner code.
  - The shell looks up `var` for you.
  - This recommendation differs slightly from the rule to always use braces.

```shell
# N.B.: Remember to declare your variables as integers when
# possible, and to prefer local variables over globals.
local -i hundred="$(( 10 * 10 ))"
declare -i five="$(( 10 / 2 ))"

# Increment the variable "i" by three.
# Note that:
#  - We do not write ${i} or $i.
#  - We put a space after the (( and before the )).
(( i += 3 ))

# To decrement the variable "i" by five:
(( i -= 5 ))

# Do some complicated computations.
# Note that normal arithmetic operator precedence is observed.
hr=2
min=5
sec=30
echo "$(( hr * 3600 + min * 60 + sec ))" # prints 7530 as expected
```

<a id="s6.10-aliases"></a>

### Aliases

- [ ] Avoid aliases in scripts, although `.bashrc` files commonly contain them.
  - The
    [Bash manual](https://www.gnu.org/software/bash/manual/html_node/Aliases.html)
    notes: "For almost every purpose, shell functions are preferred over
    aliases."
  - An alias needs careful quoting and escaping of its contents, and a mistake
    is hard to notice.
- [ ] Use a function instead of an alias. A function provides a superset of the
      functionality of an alias, so always prefer a function.

```shell
# this evaluates $RANDOM once when the alias is defined,
# so the echo'ed string will be the same on each invocation
alias random_name="echo some_prefix_${RANDOM}"
```

```shell
random_name() {
  echo "some_prefix_${RANDOM}"
}

# Note that unlike aliases function's arguments are accessed via $@
fancy_ls() {
  ls -lh "$@"
}
```

<a id="s7-naming-conventions"></a>

## Naming Conventions

<a id="s7.1-function-names"></a>

### Function Names

- [ ] Use lower-case names, with underscores between words.
- [ ] Do not namespace a standalone function.
- [ ] In a library, you may create a namespace by a prefix of the library or
      package name on all functions, with `::` as the package delimiter.
- [ ] Do not namespace in a context that works badly with colon-delimited
      names, such as auto-completion in an interactive shell.
- [ ] Put parentheses after the function name.
- [ ] Use the keyword `function` optionally, but use it consistently throughout
      a project.
- [ ] Put the braces on the same line as the function name.
- [ ] Put no space between the function name and the parenthesis.
  - The keyword is extraneous with `()` after the name, but it makes a function
    easy to identify quickly.

```shell
# Single function
my_func() {
  …
}

# Part of a package
mypackage::my_func() {
  …
}
```

<a id="s7.2-variable-names"></a>

### Variable Names

- [ ] Use the same rules as for function names.
- [ ] Name a loop variable after the variable that you loop through.

```shell
for zone in "${zones[@]}"; do
  something_with "${zone}"
done
```

<a id="s7.3-constants-and-environment-variable-names"></a>

### Constants, Environment Variables, and readonly Variables

- [ ] Capitalize a constant and anything exported to the environment.
- [ ] Separate the words with underscores.
- [ ] Declare a constant at the top of the file.

```shell
# Constant
readonly PATH_TO_FILES='/some/path'

# Both constant and exported to the environment
declare -xr ORACLE_SID='PROD'
```

- [ ] Prefer `readonly` or `export` to the equivalent `declare` command, for
      clarity.
- [ ] You may do one after the other.

```shell
# Constant
readonly PATH_TO_FILES='/some/path'
export PATH_TO_FILES
```

- [ ] You may set a constant at run time or in a conditional, but make it
      readonly immediately afterwards.

```shell
ZIP_VERSION="$(dpkg --status zip | sed -n 's/^Version: //p')"
if [[ -z "${ZIP_VERSION}" ]]; then
  ZIP_VERSION="$(pacman -Q --info zip | sed -n 's/^Version *: //p')"
fi
if [[ -z "${ZIP_VERSION}" ]]; then
  handle_error_and_quit
fi
readonly ZIP_VERSION
```

<a id="s7.4-source-filenames"></a>

### Source Filenames

- [ ] Use lower-case names, with underscores between words if desired.
  - This matches the other code styles at Google: `maketemplate` or
    `make_template`, but not `make-template`.

<a id="s7.5-use-local-variables"></a>

### Use Local Variables

- [ ] Declare a function-specific variable with `local`.
  - This keeps the variable inside the function and its children.
  - It avoids pollution of the global namespace and an inadvertent set of a
    variable that has significance outside the function.
- [ ] Use separate statements for declaration and assignment when a command
      substitution provides the value.
  - The `local` builtin does not propagate the exit code from the command
    substitution.

```shell
my_func2() {
  local name="$1"

  # Separate lines for declaration and assignment:
  local my_var
  my_var="$(my_func)"
  (( $? == 0 )) || return

  …
}
```

```shell
my_func2() {
  # DO NOT do this:
  # $? will always be zero, as it contains the exit code of 'local', not my_func
  local my_var="$(my_func)"
  (( $? == 0 )) || return

  …
}
```

<a id="s7.6-function-location"></a>

### Function Location

- [ ] Put all functions together in the file, just below the constants.
- [ ] Do not hide executable code between functions.
  - Such code makes the file difficult to follow and causes surprises when you
    debug.
- [ ] Before the declaration of functions, do only includes, `set` statements,
      and the setting of constants.

<a id="s7.7-main"></a>

### main

- [ ] Provide a function called `main` when the script is long enough to
      contain at least one other function.
- [ ] Put the main program in a function called `main` as the bottom-most
      function.
  - The start of the program is then easy to find.
  - This matches the rest of the code base.
  - This lets you declare more variables as `local`, which is not possible when
    the main code is not a function.
- [ ] Make the last non-comment line in the file a call to `main`:

```shell
main "$@"
```

- [ ] A short script with only a linear flow does not need `main`; it is
      overkill there.

<a id="s8-calling-commands"></a>

## Calling Commands

<a id="s8.1-checking-return-values"></a>

### Checking Return Values

- [ ] Always check a return value.
- [ ] Give an informative return value.
- [ ] For an unpiped command, use `$?`, or check directly with an `if`
      statement, to keep it simple.

```shell
if ! mv "${file_list[@]}" "${dest_dir}/"; then
  echo "Unable to move ${file_list[*]} to ${dest_dir}" >&2
  exit 1
fi

# Or
mv "${file_list[@]}" "${dest_dir}/"
if (( $? != 0 )); then
  echo "Unable to move ${file_list[*]} to ${dest_dir}" >&2
  exit 1
fi
```

- [ ] Use `PIPESTATUS` to check the return code of all parts of a pipe.
- [ ] If you need only the success or failure of the whole pipe, test the
      combined status; this is acceptable.

```shell
tar -cf - ./* | ( cd "${dir}" && tar -xf - )
if (( PIPESTATUS[0] != 0 || PIPESTATUS[1] != 0 )); then
  echo "Unable to tar files to ${dir}" >&2
fi
```

- [ ] Assign `PIPESTATUS` to another variable immediately after the command
      when you need different actions for errors in different parts of the
      pipe.
  - Any other command overwrites `PIPESTATUS`.
  - `[` is a command and wipes out `PIPESTATUS`.

```shell
tar -cf - ./* | ( cd "${DIR}" && tar -xf - )
return_codes=( "${PIPESTATUS[@]}" )
if (( return_codes[0] != 0 )); then
  do_something
fi
if (( return_codes[1] != 0 )); then
  do_something_else
fi
```

<a id="s8.2-builtin-commands-vs-external-commands"></a>

### Builtin Commands vs. External Commands

- [ ] Choose a shell builtin, not a separate process, when you have the choice.
- [ ] Prefer a builtin such as the
      [_Parameter Expansion_](https://www.gnu.org/software/bash/manual/html_node/Shell-Parameter-Expansion.html)
      of `bash`.
  - It is more efficient, robust, and portable, especially compared with a tool
    such as `sed`.
- [ ] Use the
      [`=~` operator](https://www.gnu.org/software/bash/manual/html_node/Conditional-Constructs.html#index-_005b_005b)
      for a regular expression match.

```shell
# Prefer this:
addition="$(( X + Y ))"
substitution="${string/#foo/bar}"
if [[ "${string}" =~ foo:(\d+) ]]; then
  extraction="${BASH_REMATCH[1]}"
fi
```

```shell
# Instead of this:
addition="$(expr "${X}" + "${Y}")"
substitution="$(echo "${string}" | sed -e 's/^foo/bar/')"
extraction="$(echo "${string}" | sed -e 's/foo:\([0-9]\)/\1/')"
```

<a id="s9-conclusion"></a>

## When in Doubt: Be Consistent

- [ ] Use one style consistently through the code base.
  - Consistency lets the team focus on other, more important issues.
  - Consistency permits automation.
  - Many rules that come from "Be Consistent" mean "Just pick one and stop
    worrying about it". The cost of arguments about flexibility is higher than
    the value of that flexibility.
- [ ] Treat consistency as a tie breaker only when there is no clear technical
      argument and no long-term direction.
- [ ] Do not use consistency as a justification for an old style without a
      weighing of:
  - the benefits of the new style;
  - the tendency of the code base to converge on newer styles over time.
