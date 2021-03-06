SSH Hans
========

A Haskell implementation of the SSH V2 Protocol.

Build the library and the example client and server with

    ln -s stack.ghc-7.10.yaml stack.yaml
    stack build --flag "ssh-hans:build_examples"

Note that the examples are not built by default, so we must enable
building them by setting the `build_examples` flag above. If you are
using Cabal instead of Stack, you can build the examples with

    cabal install --flag build_examples

See `client/README.md` and `server/README.md` for info on the example
client and server.

OpenSSH Format Keys
-------------------

We only support keys in OpenSSH format, corresponding to the `-o`
option to `ssh-keygen`. To convert an existing key to OpenSSH format:

    ssh-keygen -o -p -f ~/.ssh/id_rsa

To generate a new, password-less OpenSSH format key:

    ssh-keygen -o -N '' -f test_key

Bugs
----

1. Some OpenSSH 5.3 servers advertise support for "hmac-sha2-512", but
kex fails when this algorithm is selected for MAC in either
direction. According to OpenSSH docs [1], support for "hmac-sha2-512"
was not added until version 5.9, so I'm not sure why 5.3 servers are
advertising support.

[1] http://www.openssh.com/txt/release-5.9

Understanding the Code
----------------------

The SSH RFCs explain the protocols, messages, and network data
encodings. See http://www.snailbook.com/protocols.html for a full list
of relevant RFCs. The main RFCs relevant to understand this code are
RFCs 4250 though 4254.

This library implements both client and server functionality, and much
code is agnostic to whether it's being run in a client or server. So,
in many places we use "us" and "them" to refer "the local side of the
connection" and the "remote side of the connection".

The term "session backend" is used throughout the code to refer to a
program which interprets an "exec", "shell", or "subsystem" request on
a session channel.

The implementation usually assumes that the other end of the network
will not deviate from the protocol, and kills connections quickly if
the other end does something unexpected.

Incompleteness / Future Work
----------------------------

There is no support for checking that server signatures are known
(cf. `~/.ssh/known_hosts`) in clients.

The connection implementation in `src/Network/SSH/Connection.hs` is
incomplete; see that file for more information.
