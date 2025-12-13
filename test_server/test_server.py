from flask import Flask, request, Response, send_from_directory, redirect, jsonify, stream_with_context
import time
import os
import json
import logging

app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration for file delays (total duration in seconds)
FILE_DELAYS = {
    '5MB-test.ZIP': 1.0,
    '57MB-test.ZIP': 10.0,
    '1MB-test.bin': 0.5
}

FILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'files')

def get_json_data(request):
    """
    Attempts to get JSON data from the request.
    References request.json (if content-type is correct)
    or tries to load from request.data.
    """
    if request.is_json:
        return request.json
    
    try:
        # Try to parse data as JSON even if header is missing
        if request.data:
            return json.loads(request.data.decode('utf-8'))
    except:
        pass
    return None

@app.route('/')
def index():
    # Return a response without Content-Length, as text/html utf-8
    def generate():
        yield "Local Test Server Running"
    return Response(stream_with_context(generate()), mimetype='text/html')

@app.route('/shutdown', methods=['POST'])
def shutdown():
    """Shuts down the server."""
    shutdown_func = request.environ.get('werkzeug.server.shutdown')
    if shutdown_func:
        shutdown_func()
    return "Server shutting down..."

# ... (fail, echo_post, echo_get, redirect, upload_file, upload_binary unchanged)
# Note: I need to target specific chunks to avoid overwriting too much or duplicating.
# Let's break this down.

@app.route('/fail')
def fail():
    # Attempt to return "FORBIDDEN" as the reason phrase.
    resp = Response("Not authorized", status=403)
    resp.status = "403 FORBIDDEN" 
    return resp

@app.route('/echo_post', methods=['POST'])
def echo_post():
    """
    Echos back the request metadata and data in a dict
    """
    args = request.args.to_dict()
    data = request.data.decode('utf-8')
    json_value = get_json_data(request)
    headers = dict(request.headers)
    
    response_map = {
        'args': args,
        'data': data,
        'json': json_value,
        'headers': headers
    }
    return Response(json.dumps(response_map), mimetype='application/json')

@app.route('/echo_get', methods=['GET', 'PATCH'])
def echo_get():
    """
    Echos back the request metadata if parameter json is false,
    otherwise will return a static dict as JSON
    """
    args = request.args.to_dict()
    headers = dict(request.headers)
    response_map = {
        'args': args,
        'headers': headers
    }
    
    if request.method == 'PATCH':
        response_map['isPatch'] = True

    if request.args.get('json') == 'true':
        return Response(json.dumps(response_map), mimetype='application/json')
    else:
        return Response(f'{response_map}') # Return string representation as per original logic

@app.route('/redirect')
def redirect_endpoint():
    """
    Redirects to /echo_get with one argument redirected=true
    """
    return redirect('/echo_get?redirected=true')

@app.route('/upload_file', methods=['POST'])
def upload_file():
    """
    Testing endpoint for a multipart/form-data file upload
    """
    logger.info(f'Content-Type={request.content_type}')
    logger.info(f'Content-Length={request.content_length}')
    
    if "file" not in request.files:
         return Response('No file', 404)

    file = request.files.get("file")
    logger.info(f'Filename={file.filename}')
    
    fields = request.form.to_dict()
    json_data = json.dumps(fields)
    logger.info(f'Fields={json_data}')
    return Response(json_data, mimetype='application/json')

@app.route('/upload_binary', methods=['POST'])
def upload_binary():
    """
    Returns the file body, or the length if > 100 characters.
    Delays the read to simulate slow upload.
    """
    chunk_size = 1024 # Use small chunk size to ensure we loop a few times
    data = bytearray()
    
    # We sleep per chunk.
    
    while True:
        chunk = request.stream.read(chunk_size)
        if not chunk:
            break
        data.extend(chunk)
        time.sleep(0.05) # Sleep 50ms per 1KB chunk
        
    data_bytes = bytes(data)
    data_len = len(data_bytes)
    logger.info(f'Body length={data_len}')
    
    if data_len < 100:
        return Response(data_bytes.decode("utf-8"))
    else:
        return Response(f'{data_len}')

@app.route('/upload_multi', methods=['POST'])
def upload_multi():
    """
    Testing endpoint for a multipart/form-data multi-file upload
    """
    files_received = request.files.keys()
    logger.info(f'Files={list(files_received)}')
    
    fields = request.form.to_dict()
    json_data = json.dumps(fields)
    logger.info(f'Fields={json_data}')
    return Response(json_data, mimetype='application/json')

@app.route('/get', methods=['GET', 'HEAD'])
def httpbin_get():
    """Mimics httpbin.org/get"""
    response_map = {
        'args': request.args.to_dict(),
        'headers': dict(request.headers),
        'origin': request.remote_addr,
        'url': request.url
    }
    return jsonify(response_map)

@app.route('/post', methods=['POST'])
def httpbin_post():
    """Mimics httpbin.org/post"""
    json_data = get_json_data(request)
    form_data = request.form.to_dict()
    
    response_map = {
        'args': request.args.to_dict(),
        'data': request.data.decode('utf-8'),
        'files': {}, 
        'form': form_data,
        'headers': dict(request.headers),
        'json': json_data,
        'origin': request.remote_addr,
        'url': request.url
    }
    return jsonify(response_map)

@app.route('/put', methods=['PUT'])
def httpbin_put():
    """Mimics httpbin.org/put"""
    json_data = get_json_data(request)
    form_data = request.form.to_dict()

    response_map = {
        'args': request.args.to_dict(),
        'data': request.data.decode('utf-8') if not json_data and not form_data else "",
        'files': {},
        'form': form_data,
        'headers': dict(request.headers),
        'json': json_data,
        'origin': request.remote_addr,
        'url': request.url
    }
    return jsonify(response_map)

@app.route('/patch', methods=['PATCH'])
def httpbin_patch():
    """Mimics httpbin.org/patch"""
    json_data = get_json_data(request)
    form_data = request.form.to_dict()

    response_map = {
        'args': request.args.to_dict(),
        'data': request.data.decode('utf-8') if not json_data and not form_data else "",
        'files': {},
        'form': form_data,
        'headers': dict(request.headers),
        'json': json_data,
        'origin': request.remote_addr,
        'url': request.url
    }
    return jsonify(response_map)

@app.route('/delete', methods=['DELETE'])
def httpbin_delete():
    """Mimics httpbin.org/delete"""
    json_data = get_json_data(request)
    form_data = request.form.to_dict()

    response_map = {
        'args': request.args.to_dict(),
        'data': request.data.decode('utf-8') if not json_data and not form_data else "",
        'files': {},
        'form': form_data,
        'headers': dict(request.headers),
        'json': json_data,
        'origin': request.remote_addr,
        'url': request.url
    }
    return jsonify(response_map)


@app.route('/cookies', methods=['GET'])
def httpbin_cookies():
    """Mimics httpbin.org/cookies"""
    return jsonify({'cookies': request.cookies})

@app.route('/status/<int:code>')
def status_endpoint(code):
    """Mimics httpbin.org/status/<code>"""
    resp = Response(status=code)
    # Add reason phrases if needed/custom
    if code == 403:
        resp.status = "403 FORBIDDEN"
    elif code == 400:
        resp.status = "400 BAD REQUEST"
    return resp

@app.route('/refresh', methods=['POST'])
def refresh():
    """
    Returns JSON with new_access_token and expires_in
    """
    response_map = {
        'args': request.args.to_dict(),
        'headers': dict(request.headers),
        'post_body': request.json,
        'access_token': 'new_access_token',
        'expires_in': 3600
    }
    return Response(json.dumps(response_map), mimetype='application/json')

@app.route('/files/<path:filename>')
def serve_file(filename):
    """
    Serves files with a controlled delay, streaming the content.
    Supports partial content (Range requests).
    """
    file_path = os.path.join(FILES_DIR, filename)
    if not os.path.exists(file_path):
        return Response("File not found", 404)

    total_size = os.path.getsize(file_path)
    chunk_size = 64 * 1024 # 64KB
    
    # Range handling
    range_header = request.headers.get('Range', None)
    start_byte = 0
    end_byte = total_size - 1
    status_code = 200

    if range_header:
        try:
            # Parse 'bytes=start-end'
            range_val = range_header.replace('bytes=', '')
            parts = range_val.split('-')
            
            # Suffix range: bytes=-N (last N bytes)
            if parts[0] == '' and len(parts) > 1 and parts[1]:
                suffix_length = int(parts[1])
                start_byte = total_size - suffix_length
                end_byte = total_size - 1
            else:
                if parts[0]:
                    start_byte = int(parts[0])
                if len(parts) > 1 and parts[1]:
                    end_byte = int(parts[1])
                # Cap end byte
                if end_byte >= total_size:
                    end_byte = total_size - 1
            
            status_code = 206
        except Exception as e:
            logger.error(f"Error parsing range header: {e}")
            pass

    # Ensure start is before end
    if start_byte > end_byte:
         return Response("Requested Range Not Satisfiable", 416)

    content_length = end_byte - start_byte + 1
    
    target_duration = FILE_DELAYS.get(filename, 0)
    
    # Check for no_content_length flag
    no_content_length = request.args.get('no_content_length') == 'true'

    def generate():
        with open(file_path, 'rb') as f:
            f.seek(start_byte)
            bytes_to_send = content_length
            
            # Calculate chunks for the *requested range*
            num_chunks = (bytes_to_send + chunk_size - 1) // chunk_size
            
            # Delay per chunk
            delay_per_chunk = 0
            if target_duration > 0 and num_chunks > 0:
                delay_per_chunk = target_duration / num_chunks
            
            logger.info(f"Serving {filename} (Range: {start_byte}-{end_byte}, {content_length} bytes) in {num_chunks} chunks with {delay_per_chunk:.4f}s delay/chunk")

            while bytes_to_send > 0:
                read_size = min(chunk_size, bytes_to_send)
                chunk = f.read(read_size)
                if not chunk:
                    break
                yield chunk
                bytes_to_send -= len(chunk)
                if delay_per_chunk > 0:
                    time.sleep(delay_per_chunk)

    # Generate a simple ETag based on file size and last modified time
    # or a hash of the file path.
    file_stat = os.stat(file_path)
    etag = f'"{int(file_stat.st_mtime)}-{file_stat.st_size}"'
    last_modified = time.strftime('%a, %d %b %Y %H:%M:%S GMT', time.gmtime(file_stat.st_mtime))
    headers = {
        'Accept-Ranges': 'bytes',
        'ETag': etag,
        'Last-Modified': last_modified
    }
    
    if not no_content_length:
        headers['Content-Length'] = str(content_length)

    if status_code == 206:
        headers['Content-Range'] = f'bytes {start_byte}-{end_byte}/{total_size}'

    # Content-Disposition with filename
    headers['Content-Disposition'] = f'attachment; filename={filename}'

    # Mime Type
    if filename.lower().endswith('.zip'):
        headers['Content-Type'] = 'application/zip'
    else:
        headers['Content-Type'] = 'application/octet-stream'
    
    return Response(stream_with_context(generate()), status=status_code, headers=headers)

@app.route('/response-headers')
def response_headers():
    """
    Echoes back the query parameters as headers.
    Used for 'Set-Cookie' testing.
    """
    resp = Response("Headers set")
    for key, value in request.args.items():
        resp.headers[key] = value
    return resp

if __name__ == '__main__':
    # Use threaded=True to handle multiple concurrent requests if needed (Flask dev server default is threaded)
    app.run(host='127.0.0.1', port=8080)
