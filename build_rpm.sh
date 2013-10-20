#!/bin/sh -e
# Builds a standalone version of RPM suitable for building the bootstrap kit.
# This is required for all those platforms which do not provide a suitable rpm.

PREFIX=/usr/local/bin
BUILDPROCESSES=2
case ${ARCH} in
  osx*)
    # Darwin is not RPM based, explicitly go for quessing the triplet
    CONFIG_BUILD=quess
    ;;
  *)
    # Assume Linux distro is RPM based and fetch triplet from RPM
    CONFIG_BUILD=auto
    ;;
esac

while [ $# -gt 0 ]
do
  case "$1" in
    --prefix)
      if [ $# -lt 2 ] 
      then 
        echo "--prefix option wants an argument. Please specify the installation path." ; exit 1
      fi
      if [ ! "X`echo $2 | cut -b 1`" = "X/" ] 
      then 
        echo "--prefix takes an absolute path as an argument." ; exit 1 
      fi
      PREFIX=$2
      shift ; shift
    ;;
    --build)
      if [ $# -lt 2 ]
      then
        echo "--build requires a triplet/auto/guess as an argument."; exit 1
      fi
        CONFIG_BUILD=$2
        shift; shift
    ;;
    --arch)
       if [ $# -lt 2 ] 
       then 
         echo "--arch requires an architecture as argument." ; exit 1
       fi
       ARCH=$2
       shift ; shift
    ;;
    -j)
      if [ $# -lt 2 ]
      then
        echo "-j option wants an argument. Please specify the number of build processes." ; exit 1
      fi
      BUILDPROCESSES=$2 
      shift ; shift
    ;;
    --help)
      echo "usage: build_rpm.sh --prefix PREFIX --arch SCRAM_ARCH [-j N]"
      exit 1
    ;;
    *)
      echo "Unsupported option $1"
      exit 1
    ;;
  esac
done

set -e

[ "X${ARCH}" = X ] && echo "Please specify an architecture via --arch flag" && exit 1 
case ${ARCH} in
  *_amd64_*|*_mic_*|*_aarch64_*)
    NSPR_CONFIGURE_OPTS="--enable-64bit"
    NSS_USE_64=1
  ;;
esac

# For Mac OS X increase header size
case ${ARCH} in
  osx*)
    export LDFLAGS="-Wl,-headerpad_max_install_names"
  ;;
esac

# Needed to compile on Lion. Notice in later versions of NSS the variable
# became a Makefile internal one and needs to be passed on command line.  Keep
# this in mind if we need to move to a newer NSS.
case $ARCH in
  osx10[0-6]*) ;;
  osx*) export NSS_USE_SYSTEM_SQLITE=1 ;;
esac

HERE=$PWD

case $CONFIG_BUILD in
  auto)
    which rpm >/dev/null
    if [ $? -ne 0 ]; then
      echo "The system is not RPM based. Cannot guess build/host triplet."
      exit 1
    fi
    CONFIG_BUILD=$(rpm --eval "%{_build}")
    echo "System reports your triplet is $CONFIG_BUILD"
  ;;
  guess)
    curl -L -k -s -o ./config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'
    if [ $? -ne 0 ]; then
      echo "Could not download config.guess from git.savannah.gnu.org."
      exit 1
    fi
    chmod +x ./config.guess
    CONFIG_BUILD=$(./config.guess)
    echo "Guessed triplet is $CONFIG_BUILD"
  ;;
  *)
    curl -L -k -s -o ./config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD'
    if [ $? -ne 0 ]; then
      echo "Could not download config.sub from git.savannah.gnu.org."
      exit 1
    fi
    chmod +x ./config.sub
    CONFIG_BUILD=$(./config.sub $CONFIG_BUILD)
    echo "Adjusted triplet is $CONFIG_BUILD"
  ;;
esac

CONFIG_HOST=$CONFIG_BUILD
RPM_SOURCES=$HERE/rpm-build

# Clean up previous build
rm -rf $PREFIX
rm -rf $RPM_SOURCES
mkdir -p $PREFIX
mkdir -p $RPM_SOURCES


# Fetch the sources
TAR="tar -C $RPM_SOURCES"
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/nspr-4.10.1.tar.gz | $TAR -xvz
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/popt-1.16.tar.gz | $TAR -xvz
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/zlib-1.2.8.tar.gz | $TAR -xvz
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/nss-3.15.2.tar.gz | $TAR -xvz 
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/file-5.15.tar.gz | $TAR -xvz
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/db-6.0.20.gz | $TAR -xvz
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1.tar.bz2 | $TAR -xvj
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/cpio-2.11.tar.gz | $TAR -xvz

# Build required externals
cd $RPM_SOURCES/zlib-1.2.8
CFLAGS="-fPIC -O3 -DUSE_MMAP -DUNALIGNED_OK -D_LARGEFILE64_SOURCE=1" \
  ./configure --prefix $PREFIX --static
make -j $BUILDPROCESSES && make install

cd $RPM_SOURCES/file-5.15
# Fix config.guess to find aarch64: https://bugzilla.redhat.com/show_bug.cgi?id=925339
if [ $(uname) = Linux ]; then
  autoreconf -fiv
fi
./configure --host="${CONFIG_HOST}" --build="${CONFIG_BUILD}" --disable-rpath --enable-static \
            --disable-shared --prefix $PREFIX CFLAGS=-fPIC LDFLAGS="-L$PREFIX/lib $LDFLAGS" \
            CPPFLAGS="-I$PREFIX/include"
make -j $BUILDPROCESSES && make install

cd $RPM_SOURCES/nspr-4.10.1/nspr

# Update for AAarch64
rm -f ./nspr/build/autoconf/config.sub && curl -L -k -s -o ./nspr/build/autoconf/config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD'
rm -f ./nspr/build/autoconf/config.guess && curl -L -k -s -o ./nspr/build/autoconf/config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'

./configure --host="${CONFIG_HOST}" --build="${CONFIG_BUILD}" --disable-rpath \
            --prefix $PREFIX $NSPR_CONFIGURE_OPTS

make -j $BUILDPROCESSES && make install

cd $RPM_SOURCES/nss-3.15.2
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/nss-3.15.2-0001-Add-support-for-non-standard-location-zlib.patch | patch -p1
export USE_64=$NSS_USE_64
export NSPR_INCLUDE_DIR=$PREFIX/include/nspr
export NSPR_LIB_DIR=$PREFIX/lib
export FREEBL_LOWHASH=1
export FREEBL_NO_DEPEND=1
export BUILD_OPT=1
export NSS_NO_PKCS11_BYPASS=1
export ZLIB_INCLUDE_DIR="$PREFIX/include"
export ZLIB_LIB_DIR="$PREFIX/lib"

make -C ./nss/coreconf clean
make -C ./nss/lib/dbm clean
make -C ./nss clean
make -C ./nss/coreconf
make -C ./nss/lib/dbm
make -C ./nss 

install -d $PREFIX/include/nss3
install -d $PREFIX/lib
find ./dist/public/nss -name '*.h' -exec install -m 644 {} $PREFIX/include/nss3 \;
find ./dist/*.OBJ/lib -name '*.dylib' -o -name '*.so' -exec install -m 755 {} $PREFIX/lib \;

cd $RPM_SOURCES/popt-1.16
./configure --host="${CONFIG_HOST}" --build="${CONFIG_BUILD}" --disable-shared --enable-static \
            --disable-nls --prefix $PREFIX CFLAGS=-fPIC LDFLAGS=$LDFLAGS
make -j $BUILDPROCESSES && make install

cd $RPM_SOURCES/db-6.0.20/build_unix
../dist/configure --host="${CONFIG_HOST}" --build="${CONFIG_BUILD}" --enable-static \
                  --disable-shared --disable-java --prefix=$PREFIX \
                  --with-posixmutexes CFLAGS=-fPIC LDFLAGS=$LDFLAGS
make -j $BUILDPROCESSES && make install

# Build the actual rpm distribution.
cd $RPM_SOURCES/rpm-4.11.1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0001-Workaround-empty-buildroot-message.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0002-Increase-line-buffer-20x.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0003-Increase-macro-buffer-size-10x.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0004-Improve-file-deps-speed.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0005-Disable-internal-dependency-generator-libtool.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0006-Remove-chroot-checks.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0007-Fix-Darwin-requires-script-Argument-list-too-long.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/rpm-4.11.1-0008-Fix-Darwin-provides-script.patch | patch -p1

case $(uname) in
  Darwin)
    export DYLD_FALLBACK_LIBRARY_PATH=$PREFIX/lib
    USER_CFLAGS=-fnested-functions
    USER_LIBS=-liconv
    LIBPATHNAME=DYLD_FALLBACK_LIBRARY_PATH
  ;;
  Linux)
    export LD_FALLBACK_LIBRARY_PATH=$PREFIX/lib
    LIBPATHNAME=LD_FALLBACK_LIBRARY_PATH
  ;;
esac

./configure --host="${CONFIG_HOST}" --build="${CONFIG_BUILD}" --prefix $PREFIX \
            --with-external-db --disable-python --disable-nls --localstatedir=$PREFIX/var \
            --disable-rpath --disable-lua --without-lua \
            CFLAGS="-ggdb -O0 $USER_CFLAGS -I$PREFIX/include/nspr \
                    -I$PREFIX/include/nss3" \
            LDFLAGS="-L$PREFIX/lib $LDFLAGS" \
            CPPFLAGS="-I$PREFIX/include/nspr \
                      -I$PREFIX/include \
                      -I$PREFIX/include/nss3" \
            LIBS="-lnspr4 -lnss3 -lnssutil3 \
                  -lplds4 -lplc4 -lz -lpopt \
                  -ldb $USER_LIBS"

make -j $BUILDPROCESSES && make install

# Fix broken RPM symlinks
ln -sf $PREFIX/bin/rpm $PREFIX/bin/rpmdb
ln -sf $PREFIX/bin/rpm $PREFIX/bin/rpmsign
ln -sf $PREFIX/bin/rpm $PREFIX/bin/rpmverify
ln -sf $PREFIX/bin/rpm $PREFIX/bin/rpmquery

# Install GNU cpio
cd $RPM_SOURCES/cpio-2.11
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/cpio-2.11-0001-Protect-gets-with-HAVE_RAW_DECL_GETS-in-stdio.in.h.patch | patch -p1
curl -L -k -s -S http://davidlt.web.cern.ch/davidlt/sources/cpio-2.11-0002-Fix-invalid-redefinition-of-stat.patch | patch -p1

# Update for AAarch64
rm -f ./config.sub && curl -L -k -s -o ./config.sub 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.sub;hb=HEAD'
rm -f ./config.guess && curl -L -k -s -o ./config.guess 'http://git.savannah.gnu.org/gitweb/?p=config.git;a=blob_plain;f=config.guess;hb=HEAD'

./configure --host="${CONFIG_HOST}" --build="${CONFIG_BUILD}" --disable-rpath \
            --disable-nls --exec-prefix=$PREFIX --prefix=$PREFIX \
            CFLAGS=-fPIC LDFLAGS=$LDFLAGS
make -j $BUILDPROCESSES && make install

# For Mac OS X hardcode full paths to the RPM libraries, otherwise cmsBuild
# will fail with fatal error: "unable to find a working rpm."
if [ `uname` = Darwin ]; then
  echo "Mac OS X detected."
  echo "Fixing executables and dynamic libraries..."
  FILES=`find $PREFIX/bin -type f ; find $PREFIX/lib -name '*.dylib' -type f`
  for FILE in $FILES; do
    FILE_TYPE=`file --mime -b -n $FILE`
    if [ "$FILE_TYPE" != "application/octet-stream; charset=binary" ]; then
      continue
    fi

    NUM=`otool -L $FILE | grep '@executable_path' | wc -l`
    if [ $NUM -ne 0 ]; then
      FIX_TYPE="Executable:"
      SO_PATHS=`otool -L $FILE | grep '@executable_path' | cut -d ' ' -f 1`

      for SO_PATH in $SO_PATHS; do
        LIB_NAME=`echo $SO_PATH | cut -d '/' -f 2`
        install_name_tool -change $SO_PATH $PREFIX/lib/$LIB_NAME $FILE
      done

      case $FILE in
        *.dylib)
          FIX_TYPE="Library:"
          SO_NAME=`otool -L $FILE | head -n 1 | cut -d ':' -f 1`
          install_name_tool -id $SO_NAME $FILE
        ;;
      esac

      echo "$FIX_TYPE $FILE"
    fi

  done
fi

echo "Removing broken symlinks..."
for i in `find $PREFIX/bin -type l`; do
  if [ ! -e $i ]; then
    echo "Broken symlink: $i"
    rm -f $i
  fi
done

perl -p -i -e 's|^.buildroot|#%%buildroot|' $PREFIX/lib/rpm/macros
echo "# Build done."
echo "# Please add $PREFIX/lib to your $LIBPATHNAME and $PREFIX/bin to your path in order to use it."
echo "# E.g. "
echo "export PATH=$PREFIX/bin:\$PATH"
echo "export $LIBPATHNAME=$PREFIX/lib:\$$LIBPATHNAME"
