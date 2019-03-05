FROM ubuntu:18.04

RUN apt update && apt install -y pkg-config cmake clang git wget unzip uuid-dev ruby

RUN mkdir -p /src && mkdir -p /osquery_configs && mkdir /data && cd /data && mkdir antlrbuild && cd antlrbuild && \
  wget https://www.antlr.org/download/antlr4-cpp-runtime-4.7.2-source.zip \
  && unzip antlr*.zip && mkdir build && cd build \
  && ANTLR4_INSTALL=/usr cmake .. && make && make install

# get and build prettysql
RUN git clone https://github.com/packetzero/prettysql.git \
  && cd prettysql && mkdir build && ./make_deps.sh \
  && cd deps/simplesql && ./make_deps.sh && mkdir build && cd build \
  && cmake .. && make && cd ../../.. \
  && pwd && cd build \
  && cmake -DCMAKE_CXX_FLAGS=-DPRETTYSQL_JSON=1 .. && make && cp `find . -type f -name prettysql` /usr/local/bin/

# copy this repo files into /src
# specify -v on command-line to override
COPY ./* /src
VOLUME /src

# user config files in /osq_configs
# specify -v on command-line to access host config files
RUN mkdir -p /osq_configs
VOLUME /osq_configs

ENTRYPOINT ["/src/docker_entrypoint.sh"]

EXPOSE 8000
