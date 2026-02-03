# =========================
# 1) BUILDER STAGE
# =========================
FROM unidata/tomcat-docker:10-jdk17 AS builder

USER root

# ---- netcdf / hdf5 / zlib versions
ENV HDF5_VERSION=1.12.2
ENV ZLIB_VERSION=1.2.9
ENV NETCDF_VERSION=4.9.2

ENV ZDIR=/usr/local
ENV H5DIR=/usr/local
ENV PDIR=/usr
ENV HDF5_VER=hdf5-${HDF5_VERSION}
ENV HDF5_FILE=${HDF5_VER}.tar.gz

# ---- thredds
ENV THREDDS_WAR_URL=https://downloads.unidata.ucar.edu/tds/5.8/thredds-5.8.war

# Build deps (builder only)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential m4 \
      libpthread-stubs0-dev libcurl4-openssl-dev \
      zip unzip curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# ---- Build zlib
RUN curl -fsSL https://zlib.net/fossils/zlib-${ZLIB_VERSION}.tar.gz | tar xz && \
    cd zlib-${ZLIB_VERSION} && \
    ./configure --prefix=/usr/local && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf zlib-${ZLIB_VERSION}

# ---- Build HDF5
RUN curl -fsSL https://support.hdfgroup.org/ftp/HDF5/releases/${HDF5_VER%.*}/${HDF5_VER}/src/${HDF5_FILE} | tar xz && \
    cd hdf5-${HDF5_VERSION} && \
    ./configure \
      --with-zlib=${ZDIR} \
      --with-pthread=${PDIR} \
      --enable-threadsafe \
      --enable-unsupported \
      --prefix=/usr/local && \
    make -j"$(nproc)" && make install && ldconfig && \
    cd .. && rm -rf hdf5-${HDF5_VERSION}

# ---- Build netCDF-C
RUN export CPPFLAGS="-I/usr/local/include" LDFLAGS="-L/usr/local/lib" && \
    curl -fsSL https://downloads.unidata.ucar.edu/netcdf-c/${NETCDF_VERSION}/netcdf-c-${NETCDF_VERSION}.tar.gz | tar xz && \
    cd netcdf-c-${NETCDF_VERSION} && \
    ./configure --disable-dap-remote-tests --disable-libxml2 --prefix=/usr/local && \
    make -j"$(nproc)" && make install && ldconfig && \
    cd .. && rm -rf netcdf-c-${NETCDF_VERSION}

# ---- Prepare THREDDS webapp (exploded)
RUN mkdir -p /tmp/thredds && \
    curl -fSL "${THREDDS_WAR_URL}" -o /tmp/thredds/thredds.war && \
    unzip /tmp/thredds/thredds.war -d /tmp/thredds/thredds && \
    rm -f /tmp/thredds/thredds.war

# ---- (Optional) keep some netcdf tools if you want them in runtime
# They live in /usr/local/bin (e.g., nc-config, ncdump). We'll copy selectively later.


# =========================
# 2) RUNTIME STAGE (final image)
# =========================
FROM unidata/tomcat-docker:10-jdk17

USER root

# Runtime envs
ENV LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH}
ENV TDS_CONTENT_ROOT_PATH=/usr/local/tomcat/content
ENV THREDDS_XMX_SIZE=4G
ENV THREDDS_XMS_SIZE=4G

# Runtime packages only
# - gosu: used by unidata/tomcat-docker entrypoint
# - curl: required by HEALTHCHECK below (keep if you keep that healthcheck)
RUN apt-get update && \
    apt-get install -y --no-install-recommends gosu curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# ---- Copy ONLY shared libraries (.so) from builder
# (Generic approach: copy all shared libs installed in /usr/local/lib)
COPY --from=builder /usr/local/lib/*.so* /usr/local/lib/
RUN ldconfig

# ---- If you need netcdf user tools at runtime, copy them explicitly (optional)
# COPY --from=builder /usr/local/bin/nc-config /usr/local/bin/
# COPY --from=builder /usr/local/bin/ncdump    /usr/local/bin/

# ---- Copy THREDDS webapp prepared in builder
COPY --from=builder /tmp/thredds/thredds ${CATALINA_HOME}/webapps/thredds/

# ---- Your configs/scripts (from build context)
COPY files/threddsConfig.xml ${CATALINA_HOME}/content/thredds/threddsConfig.xml
COPY files/tomcat-users.xml  ${CATALINA_HOME}/conf/tomcat-users.xml
COPY files/setenv.sh         ${CATALINA_HOME}/bin/setenv.sh
COPY files/javaopts.sh       ${CATALINA_HOME}/bin/javaopts.sh

# ---- Ensure directories & permissions
RUN mkdir -p ${CATALINA_HOME}/content/thredds && \
    mkdir -p ${CATALINA_HOME}/javaUtilPrefs/.systemPrefs && \
    chmod 755 ${CATALINA_HOME}/bin/*.sh

EXPOSE 8080 8443
WORKDIR ${CATALINA_HOME}

# Inherited from parent container
ENTRYPOINT ["/entrypoint.sh"]

# Start container
CMD ["catalina.sh", "run"]

HEALTHCHECK --interval=10s --timeout=3s \
  CMD curl --fail 'http://localhost:8080/thredds/catalog.html' || exit 1
