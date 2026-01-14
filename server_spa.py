import http.server
import socketserver
import os

PORT = 8000
DIRECTORY = "build/web"

class SPAHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        # Ensure we serve from the build/web directory
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def do_GET(self):
        # proper path handling
        url_path = self.path.split('?')[0]
        
        # Get the absolute path on the filesystem
        path = self.translate_path(url_path)
        
        # If the file doesn't exist (and it's not a directory request which might automatically look for index.html)
        if not os.path.exists(path):
            # It's an SPA route, serve index.html
            self.path = '/index.html'
        
        return http.server.SimpleHTTPRequestHandler.do_GET(self)

if __name__ == "__main__":
    # Allow address reuse
    socketserver.TCPServer.allow_reuse_address = True
    
    with socketserver.TCPServer(("", PORT), SPAHandler) as httpd:
        print(f"Serving Flutter Web SPA at http://localhost:{PORT}")
        print(f"Mapping all unknown routes to {DIRECTORY}/index.html")
        httpd.serve_forever()
