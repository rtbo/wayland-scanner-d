wayland-scanner-d
======

Wayland protocol scanner that generates D code.

Example of client code generation:


    #! /bin/bash

    PROTOCOL=$WLD/protocol/wayland.xml
    SCANNER=wayland-scanner-d

    # generate main protocol file
    cat $PROTOCOL | $SCANNER -m wayland.client.protocol \
            --client --protocol -o src/wayland/client/protocol.d \
            -x wayland.client.core -x wayland.client.ifaces

    # generate interfaces file
    # need of a separate module to avoid name collision
    # (mainly because of server code)
    cat $PROTOCOL | $SCANNER -m wayland.client.ifaces \
            --client --ifaces --ifaces_priv_mod wayland.client.priv.ifaces \
            -o src/wayland/client/ifaces.d

    # generate private interface file
    # need of this module also for implementation detail and name collision
    cat $PROTOCOL | $SCANNER -m wayland.client.priv.ifaces \
            --client --ifaces --ifaces_priv \
            -o src/wayland/client/priv/ifaces.d

help information:

    $ wayland-scanner-d --help
    A Wayland protocol scanner and D code generator
    -i           --input input file [defaults to stdin]
    -o          --output output file [defaults to stdout]
    -m          --module D module name [required]
                --client client mode
                --server server mode
              --protocol outputs main protocol code
                --ifaces outputs interfaces code
           --ifaces_priv outputs private interface code
       --ifaces_priv_mod specify the private interface module
    -x          --import external modules to import
    -p          --public external modules to import publicly
    -h            --help This help information.
