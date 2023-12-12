#!/usr/bin/env bash
#
# File:        git-archive-all.sh
#
# Description: A utility script that builds an archive file(s) of all
#              git repositories and submodules in the current path.
#              Useful for creating a single tarfile of a git super-
#              project that contains other submodules.
#
# Examples:    Use git-archive-all.sh to create archive distributions
#              from git repositories. To use, simply do:
#
#                  cd $GIT_DIR; git-archive-all.sh
#
#              where $GIT_DIR is the root of your git superproject.
#
# License:     GPL3
#
###############################################################################
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
#
###############################################################################

# DEBUGGING
set -e
set -C # noclobber

# TRAP SIGNALS
trap 'cleanup' QUIT EXIT    # 脚本退出时执行清理操作

# For security reasons, explicitly set the internal field separator
# to newline, space, tab
# 出于安全原因，将内部字段分隔符显式设置为换行符、空格、制表符
OLD_IFS=$IFS
IFS='
 	'

function cleanup () {
    rm -rf $TMPDIR  # 删除临时文件
    IFS="$OLD_IFS"  # 恢复分隔符
}

function usage () {
    echo "Usage is as follows:"
    echo
    echo "$PROGRAM <--version>"
    echo "    Prints the program version number on a line by itself and exits."
    echo
    echo "$PROGRAM <--usage|--help|-?>"
    echo "    Prints this usage output and exits."
    echo
    echo "$PROGRAM [--format <fmt>] [--prefix <path>] [--verbose|-v] [--separate|-s]"
    echo "         [--tree-ish|-t <tree-ish>] [--ignore pattern] [output_file]"
    echo "    Creates an archive for the entire git superproject, and its submodules"
    echo "    using the passed parameters, described below."
    echo
    echo "    If '--format' is specified, the archive is created with the named"
    echo "    git archiver backend. Obviously, this must be a backend that git archive"
    echo "    understands. The format defaults to 'tar' if not specified."
    echo
    echo "    If '--prefix' is specified, the archive's superproject and all submodules"
    echo "    are created with the <path> prefix named. The default is to not use one."
    echo
    echo "    If '--separate' or '-s' is specified, individual archives will be created"
    echo "    for each of the superproject itself and its submodules. The default is to"
    echo "    concatenate individual archives into one larger archive."
    echo
    echo "    If '--tree-ish' is specified, the archive will be created based on whatever"
    echo "    you define the tree-ish to be. Branch names, commit hash, etc. are acceptable."
    echo "    Defaults to HEAD if not specified. See git archive's documentation for more"
    echo "    information on what a tree-ish is."
    echo
    echo "    If '--ignore' is specified, we will filter out any submodules that"
    echo "    match the specified pattern."
    echo
    echo "    If 'output_file' is specified, the resulting archive is created as the"
    echo "    file named. This parameter is essentially a path that must be writeable."
    echo "    When combined with '--separate' ('-s') this path must refer to a directory."
    echo "    Without this parameter or when combined with '--separate' the resulting"
    echo "    archive(s) are named with a dot-separated path of the archived directory and"
    echo "    a file extension equal to their format (e.g., 'superdir.submodule1dir.tar')."
    echo
    echo "    If '--verbose' or '-v' is specified, progress will be printed."
}

function version () {
    echo "$PROGRAM version $VERSION"
}

# Internal variables and initializations.
readonly PROGRAM=`basename "$0"`
readonly VERSION=0.2

OLD_PWD="`pwd`"     # 保存当前目录
TMPDIR=`mktemp -d "${TMPDIR:-/tmp}/$PROGRAM.XXXXXX"`    # 创建临时目录
TMPFILE=`mktemp "$TMPDIR/$PROGRAM.XXXXXX"` # Create a place to store our work's progress    创建一个存储工作进度的文件
TOARCHIVE=`mktemp "$TMPDIR/$PROGRAM.toarchive.XXXXXX"`  # 创建一个归档文件
OUT_FILE=$OLD_PWD # assume "this directory" without a name change by default    默认情况下假定“这个目录”不更改名称
SEPARATE=0  # 是否拆分归档文件，如果是的话`OUT_FILE`必须是一个已存在的目录
VERBOSE=0   # 是否打印详细信息

TARCMD=tar
[[ $(uname) == "Darwin" ]] && TARCMD=gnutar
FORMAT=tar
PREFIX=
TREEISH=HEAD
IGNORE=

# RETURN VALUES/EXIT STATUS CODES
readonly E_BAD_OPTION=254
readonly E_UNKNOWN=255

# Process command-line arguments.
while test $# -gt 0; do
    case $1 in
        --format )
            shift
            FORMAT="$1"
            shift
            ;;

        --prefix )
            shift
            PREFIX="$1"
            shift
            ;;

        --separate | -s )
            shift
            SEPARATE=1
            ;;

        --tree-ish | -t )
            shift
            TREEISH="$1"
            shift
            ;;

	--ignore )
	    shift
	    IGNORE="$1"
	    shift
	    ;;

        --version )
            version
            exit
            ;;

        --verbose | -v )
            shift
            VERBOSE=1
            ;;

        -? | --usage | --help )
            usage
            exit
            ;;

        -* )
            echo "Unrecognized option: $1" >&2
            usage
            exit $E_BAD_OPTION
            ;;

        * )
            break
            ;;
    esac
done

if [ ! -z "$1" ]; then
    OUT_FILE="$1"   # 使用指定的文件名
    shift
fi

# Validate parameters; error early, error often.
if [ $SEPARATE -eq 1 -a ! -d $OUT_FILE ]; then
    echo "When creating multiple archives, your destination must be a directory."   # 创建多个存档时，目标必须是一个目录。
    echo "If it's not, you risk being surprised when your files are overwritten."   # 如果不是，当您的文件被覆盖时，您可能会感到惊讶。
    exit
elif [ `git config -l | grep -q '^core\.bare=false'; echo $?` -ne 0 ]; then
    echo "$PROGRAM must be run from a git working copy (i.e., not a bare repository)."  # 当前目录必须是一个git工作目录，而非一个bare仓库
    exit
fi

# Create the superproject's git-archive
if [ $VERBOSE -eq 1 ]; then
    echo -n "creating superproject archive..."
fi
# 打包源码
git archive --format=$FORMAT --prefix="$PREFIX" $TREEISH > $TMPDIR/$(basename "$(pwd)").$FORMAT
if [ $VERBOSE -eq 1 ]; then
    echo "done"
fi
echo $TMPDIR/$(basename "$(pwd)").$FORMAT >| $TMPFILE # clobber on purpose
superfile=`head -n 1 $TMPFILE`

if [ $VERBOSE -eq 1 ]; then
    echo -n "looking for subprojects..."
fi
# find all '.git' dirs, these show us the remaining to-be-archived dirs
# we only want directories that are below the current directory
# 找到所有的“.git”目录，这些目录会向我们显示剩余的要存档的目录，我们只想要当前目录下的目录
find . -mindepth 2 -name '.git' -type d -print | sed -e 's/^\.\///' -e 's/\.git$//' >> $TOARCHIVE
# as of version 1.7.8, git places the submodule .git directories under the superprojects .git dir
# the submodules get a .git file that points to their .git dir. we need to find all of these too
# 从1.7.8版本开始，git将子模块.git目录放在superprojects.git-dir下，子模块会得到一个指向其.git目录的.git文件。我们也需要找到所有这些
find . -mindepth 2 -name '.git' -type f -print | xargs grep -l "gitdir" | sed -e 's/^\.\///' -e 's/\.git$//' >> $TOARCHIVE

if [ -n "$IGNORE" ]; then
    # 传递给脚本的参数中带有`--ignore corpus`参数，则忽略掉指定的子模块
    cat $TOARCHIVE | grep -v $IGNORE > $TOARCHIVE.new
    mv $TOARCHIVE.new $TOARCHIVE
fi

if [ $VERBOSE -eq 1 ]; then
    echo "done"
    echo "  found:"
    cat $TOARCHIVE | while read arch
    do
      echo "    $arch"
    done
fi

if [ $VERBOSE -eq 1 ]; then
    echo -n "archiving submodules..."
fi
while read path; do
    # 打包各个子模块
    TREEISH=$(git submodule | grep "^ .*${path%/} " | cut -d ' ' -f 2) # git submodule does not list trailing slashes in $path
    cd "$path"
    git archive --format=$FORMAT --prefix="${PREFIX}$path" ${TREEISH:-HEAD} > "$TMPDIR"/"$(echo "$path" | sed -e 's/\//./g')"$FORMAT
    if [ $FORMAT == 'zip' ]; then
        # delete the empty directory entry; zipped submodules won't unzip if we don't do this
        zip -d "$(tail -n 1 $TMPFILE)" "${PREFIX}${path%/}" >/dev/null # remove trailing '/'
    fi
    echo "$TMPDIR"/"$(echo "$path" | sed -e 's/\//./g')"$FORMAT >> $TMPFILE
    cd "$OLD_PWD"
done < $TOARCHIVE
if [ $VERBOSE -eq 1 ]; then
    echo "done"
fi

if [ $VERBOSE -eq 1 ]; then
    echo -n "concatenating archives into single archive..."
fi
# Concatenate archives into a super-archive.
# 将多个归档文件合并为一个
if [ $SEPARATE -eq 0 ]; then
    if [ $FORMAT == 'tar' ]; then
        sed -e '1d' $TMPFILE | while read file; do
            $TARCMD --concatenate -f "$superfile" "$file" && rm -f "$file"
        done
    elif [ $FORMAT == 'zip' ]; then
        sed -e '1d' $TMPFILE | while read file; do
            # zip incorrectly stores the full path, so cd and then grow
            cd `dirname "$file"`
            zip -g "$superfile" `basename "$file"` && rm -f "$file"
        done
        cd "$OLD_PWD"
    fi

    echo "$superfile" >| $TMPFILE # clobber on purpose
fi
if [ $VERBOSE -eq 1 ]; then
    echo "done"
fi

if [ $VERBOSE -eq 1 ]; then
    echo -n "moving archive to $OUT_FILE..."
fi
while read file; do
    mv "$file" "$OUT_FILE"
done < $TMPFILE
if [ $VERBOSE -eq 1 ]; then
    echo "done"
fi
