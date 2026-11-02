import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import TLS_FTPHandler
from pyftpdlib.servers import FTPServer

port, root, user, password, cert, key = sys.argv[1:7]
authorizer = DummyAuthorizer()
authorizer.add_user(user, password, root, perm="elradfmwMT")
handler = TLS_FTPHandler
handler.authorizer = authorizer
handler.certfile = cert
handler.keyfile = key
handler.tls_control_required = False
handler.tls_data_required = False
FTPServer(("127.0.0.1", int(port)), handler).serve_forever()
