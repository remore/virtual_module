FROM julia:latest
RUN julia -e 'Pkg.add("MsgPack"); Pkg.add("MsgPackRpcServer")'
