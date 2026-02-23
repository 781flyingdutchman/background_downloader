# Testing Instructions

To run integration tests for the `background_downloader` package (which are more important than the standard dart unit tests), follow these steps:

1. Start the test server:
   ```bash
   python test_server/test_server.py
   ```
2. Navigate to the `example` directory:
   ```bash
   cd example
   ```
3. Run the integration tests script:
   ```bash
   ./run_tests.sh
   ```

**Important Notes:**
- Some integration tests can be a little flaky. A failure doesn't necessarily mean a code change is required.
- Often, re-running only the specific failing integration test is sufficient to confirm if it worked.
- The integration test suite takes approximately 10 to 15 minutes to complete. Check back periodically (every 3 minutes).
