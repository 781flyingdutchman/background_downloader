# .github/workflows/triage.py

import os
import google.generativeai as genai
from github import Github

# --- Configuration ---
# Get secrets and context from environment variables set in the YAML file
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY")
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
REPO_NAME = os.getenv("REPO_NAME")
ISSUE_NUMBER = int(os.getenv("ISSUE_NUMBER"))
ISSUE_TITLE = os.getenv("ISSUE_TITLE")
ISSUE_BODY = os.getenv("ISSUE_BODY")

# Configure the Gemini AI model
genai.configure(api_key=GEMINI_API_KEY)
model = genai.GenerativeModel('gemini-2.5-pro')

# --- Craft the AI Prompt ---
prompt = f"""
You are "Winston", an expert AI assistant for the GitHub repository '{REPO_NAME}'.
Your role is to perform an initial triage of newly filed issues

**Your Task:**
Analyze the following issue and provide an initial response. Your response should:
1.  Introduce yourself as a bot, attempting to help with the issue and claarifying that the response provided is AI generated and may not be correct.
2.  Acknowledge and briefly summarize the issue to show you've understood it.
3.  Evauate the issue for completeness: is there enough information (such as specific description of the issue or request, code snippets if relevant, logs if relevant)? If not, include a request for the missing information in your response, so the submitter can add this
4.  Search across all issues in the repository to see if there is a similar issue there, and especially read the repository's README.md file to understand how the package is supposed to be used. If a solution is found, include a reference to this other issue (or issues) or a reference to the documentation in your response, so that the submitter can check those out and perhaps solve the problem immediately.
5.  Provide an initial assessment and/or recommendation. This could be asking for more information (like logs or screenshots), suggesting potential workarounds (based on you rundertanding of the package), or identifying it as a likely bug, feature request, or documentation issue.
6.  If the issue appears to be a bug or feature request for which there is no exisitng answeer, then scan the repo code and see if you can suggest an initial area for the maintainer to explore, to address the issue or add the feature. If you have a suggestion, then include this in your response as a separate paragraph, and start that paragraph with "Suggestion for maitainer:" or something similar, to clearly separate it from your response to the submitter. 
7.  End with a polite closing, stating that the maintainer will review the issue in more detail. If you have made a recommendation for additional information or have a concrete suggestion for the submitter to try to resolve, then include in your closing a suggestion for them to try your recommendation (and perhaps close the issue if it was resolved that way)

Keep your tone helpful, professional, and concise. Format your response in Markdown.

**Issue Details:**
- **Title:** "{ISSUE_TITLE}"
- **Body:**
"{ISSUE_BODY}"

---
**Winston's Triage Response:**
"""

# --- Main Execution ---
try:
    print("Generating AI response...")
    # Call the AI model
    response = model.generate_content(prompt)
    ai_response_text = response.text

    print("Connecting to GitHub...")
    # Authenticate with the GitHub API
    g = Github(GITHUB_TOKEN)
    repo = g.get_repo(REPO_NAME)
    issue = repo.get_issue(number=ISSUE_NUMBER)

    print(f"Posting comment to issue #{ISSUE_NUMBER}...")
    # Post the AI's response as a comment
    issue.create_comment(ai_response_text)

    print("Comment posted successfully!")

except Exception as e:
    print(f"An error occurred: {e}")
    # If the AI fails, post a generic error message
    # This ensures the workflow doesn't fail silently.
    fallback_message = (
        "An error occurred while trying to generate an AI-powered triage response. "
        "The maintainer will review this issue shortly."
    )
    try:
        g = Github(GITHUB_TOKEN)
        repo = g.get_repo(REPO_NAME)
        issue = repo.get_issue(number=ISSUE_NUMBER)
        issue.create_comment(fallback_message)
    except Exception as github_e:
        print(f"Failed to post fallback comment: {github_e}")
