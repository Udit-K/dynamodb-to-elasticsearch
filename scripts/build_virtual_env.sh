#!/bin/bash
set -e
set -o pipefail

upsearch () {
  slashes=${PWD//[^\/]/}
  directory="$PWD"
  for (( n=${#slashes}; n>0; --n ))
  do
    test -d "$directory/$1" && return
    directory="$directory/.."
  done
}

# Parse options
while [[ $# > 0 ]]
do
key="$1"
shift

case $key in
    --rebuild)
    FORCE_REBUILD=1
    ;;
    --directory)
    BUILD_DIR="$1"
    shift
    ;;
    --wheel-cache)
    WHEEL_CACHE_DIR="$1"
    shift
    ;;
    --skip-reinstall)
    SKIP_REINSTALL=1
    ;;
    --dry-run)
    DRY_RUN=1
    ;;
    --deploy)
    DEPLOY_READY=1
    ;;
    --use-current-env)
    USE_CURRENT_ENV=1
    ;;
    --symlink-only)
    SYMLINK_ONLY=1
    ;;
    --pypi-timeout)
    PYPI_TIMEOUT="$1"
    shift
    ;;
    *)
            # unknown option
    ;;
esac
done


PWD=`pwd`

upsearch .git

dirname_0="$(cd "$(dirname $0)"; pwd)"
pushd $directory > /dev/null

: ${DRY_RUN:=0}
: ${REBUILD:=1}
: ${SKIP_REINSTALL:=0}
: ${FORCE_REBUILD:=0}
: ${OLD_BUILD_DIR:="$PWD/.virtualenv"}
: ${BUILD_DIR:="$PWD/.virtualenvs/$(uname -s)-$(uname -r)-$(arch)"}
: ${WHEEL_CACHE_DIR:="$PWD/.cache/wheel/$(uname -s)-$(uname -r)-$(arch)"}
: ${DEPLOY_READY:=0}
: ${USE_CURRENT_ENV:=0}
: ${PYPI_TIMEOUT:=1}
: ${SYMLINK_ONLY:=0}
: ${TRAVIS_PYTHON_VERSION:="3.5"}

echo "Python Version $TRAVIS_PYTHON_VERSION"

REQ_VERSION=$(cat requirements/* |sort)

NEEDS_REBUILD=1

if [ $USE_CURRENT_ENV -eq 0 ]
then
    if [ $DRY_RUN -eq 0 ]
    then
        echo "Building to $BUILD_DIR"
    fi

    if [ -d $BUILD_DIR ]
    then
        pushd $BUILD_DIR > /dev/null
        if [ -f req_version ]
        then
            PREV_VERSION=$(cat req_version)
            if [ $FORCE_REBUILD -eq 0 ] && [ "$PREV_VERSION" == "$REQ_VERSION" ]
            then
                REBUILD=0
                NEEDS_REBUILD=0
            fi
        fi
        popd > /dev/null
        if [ $FORCE_REBUILD -eq 1 ] || [ $REBUILD -eq 1 ]
        then
            NEEDS_REBUILD=1
            if [ $DRY_RUN -eq 0 ]
            then
                echo "Cleaning .virtualenv"
                rm -rf $BUILD_DIR
                rm -rf $OLD_BUILD_DIR
            fi
        fi
    fi

    if [ $SYMLINK_ONLY -eq 1 ]
    then
        if [ -d $OLD_BUILD_DIR ] || [ -h $OLD_BUILD_DIR ] || [ -a $OLD_BUILD_DIR ]
        then
            rm -rf $OLD_BUILD_DIR
        fi
    fi

    if [ $DRY_RUN -eq 1 ]
    then
        if [ $NEEDS_REBUILD -eq 1 ]
        then
            echo "=== WARNING: Virtual env out of date! ===" 1>&2;
            echo "These are the dependencies that have changed:" 1>&2;
            diff <(echo "$PREV_VERSION") <(echo "$REQ_VERSION")
            echo "=== WARNING: Virtual env out of date! ===" 1>&2;
            popd > /dev/null
            exit 1
        fi
        echo "Virtual env up to date."
        popd > /dev/null
        exit 0
    fi

    if [ $NEEDS_REBUILD -eq 0 ]
    then
        if [ $SKIP_REINSTALL -eq 1 ]
        then
            echo "Skipping reinstall of existing virtual env."
            popd > /dev/null
            exit 0
        fi
    fi

    if [ ! -d $BUILD_DIR ]
    then
        mkdir -p $BUILD_DIR
        virtualenv  -p python$TRAVIS_PYTHON_VERSION $BUILD_DIR
    fi

    if [ -d $OLD_BUILD_DIR ]  # check if dir - delete it
    then
        rm -rf ${OLD_BUILD_DIR}
    fi

    if [ ! -h $OLD_BUILD_DIR ] || [ "$(readlink $OLD_BUILD_DIR)" = "$BUILD_DIR" ] # check if symlink
    then
        ln -s ${BUILD_DIR} ${OLD_BUILD_DIR}
    fi

    echo "Updated .virtualenv symlink to: $(readlink $OLD_BUILD_DIR)"

    if [ $SYMLINK_ONLY -eq 1 ]
    then
        exit 0
    fi

    source $BUILD_DIR/bin/activate
fi

# Clean up lingering wheels b/c they don't play nice
if [ -d ~/.cache/pip/wheels ]
then
    rm -rf ~/.cache/pip/wheels
fi

# This happens in travis as well
if [ ! -d $WHEEL_CACHE_DIR ]
then
    mkdir -p $WHEEL_CACHE_DIR
fi

pip3 install --upgrade pip
pip3 install --upgrade setuptools
pip3 install --upgrade wheel
time pip3 wheel --use-wheel --wheel-dir $WHEEL_CACHE_DIR --find-links $WHEEL_CACHE_DIR -r requirements/base.txt --timeout $PYPI_TIMEOUT
time pip3 install -r requirements/base.txt --use-wheel --find-links $WHEEL_CACHE_DIR
time pip3 wheel --use-wheel --wheel-dir $WHEEL_CACHE_DIR --find-links $WHEEL_CACHE_DIR -r requirements/base-private.txt --timeout $PYPI_TIMEOUT
time pip3 install -r requirements/base-private.txt --use-wheel --find-links $WHEEL_CACHE_DIR

if [ $DEPLOY_READY -eq 0 ]
then
    time pip3 wheel --wheel-dir $WHEEL_CACHE_DIR --find-links $WHEEL_CACHE_DIR -r requirements/dev.txt --timeout $PYPI_TIMEOUT
    time pip3 install -r requirements/dev.txt --use-wheel --find-links $WHEEL_CACHE_DIR
    time pip3 wheel --wheel-dir $WHEEL_CACHE_DIR --find-links $WHEEL_CACHE_DIR -r requirements/dev-private.txt --timeout $PYPI_TIMEOUT
    time pip3 install --upgrade -r requirements/dev-private.txt --use-wheel --find-links $WHEEL_CACHE_DIR
fi


if [ $USE_CURRENT_ENV -eq 0 ]
then
    deactivate

    if [ $? -ne 0 ]
    then
        echo 'PIP INSTALL FAILED'
        popd > /dev/null
        exit 1
    fi

    echo "$REQ_VERSION" > $BUILD_DIR/req_version

    touch /tmp/uwsgi-reload

    popd > /dev/null
fi

exit 0
