#!/bin/bash
# Test script for Text-to-SQL generation using the RHAII vLLM inference API.
# Usage: ./test-text-to-sql.sh [API_ENDPOINT] [API_KEY]
#   API_ENDPOINT  default: http://localhost:8000
#   API_KEY       default: (none, no auth header sent)
#
# Prerequisites: curl, python3 (or jq)

API_ENDPOINT="${1:-http://localhost:8000}"
API_KEY="$2"

AUTH_ARGS=()
if [ -n "$API_KEY" ]; then
  AUTH_ARGS=(-H "Authorization: Bearer $API_KEY")
fi

SYSTEM_PROMPT='You are a SQL expert. Given the following database schema and a natural language question, generate the correct SQL query. Only output the SQL query, no explanation.\n\nSchema:\n- table: employees (id INT, name VARCHAR, department VARCHAR, salary DECIMAL, hire_date DATE)\n- table: departments (id INT, name VARCHAR, manager_id INT, budget DECIMAL)\n- table: projects (id INT, name VARCHAR, department_id INT, start_date DATE, end_date DATE, status VARCHAR)'

run_test() {
  local test_name="$1"
  local question="$2"

  echo "============================================"
  echo "TEST: $test_name"
  echo "Question: $question"
  echo "--------------------------------------------"

  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'model': 'mistral-small-3.1-24b-instruct',
    'messages': [
        {'role': 'system', 'content': '$SYSTEM_PROMPT'},
        {'role': 'user', 'content': '$question'}
    ],
    'max_tokens': 300,
    'temperature': 0.1
}))
")

  RESPONSE=$(curl -s "$API_ENDPOINT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    "${AUTH_ARGS[@]}" \
    -d "$PAYLOAD")

  echo "$RESPONSE" | python3 -c "
import sys, json
try:
    r = json.load(sys.stdin)
    if 'choices' in r:
        print('Generated SQL:')
        print(r['choices'][0]['message']['content'])
    else:
        print('ERROR:', json.dumps(r, indent=2))
except Exception as e:
    print(f'ERROR: {e}')
"
  echo ""
}

echo ""
echo "RHAII Text-to-SQL Test Suite"
echo "Endpoint: $API_ENDPOINT"
echo "API Key:  ${API_KEY:+(set)}"
echo ""

run_test "Basic aggregation with JOIN" \
  "Find the top 3 departments with the highest average salary, show department name, average salary, and employee count."

run_test "HAVING clause with calculated field" \
  "List all departments where the total employee salary exceeds the department budget, with the overspend amount, sorted by overspend descending."

run_test "Multi-table JOIN with filter" \
  "Show all active projects along with their department name and the number of employees in that department."

echo "============================================"
echo "All tests completed."
