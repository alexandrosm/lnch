@echo off
if "%1 %2"=="api user" (
  echo {"login":"octocat","name":"Mona Lisa","id":12345,"email":"mona@example.com"}
  exit /b 0
)
exit /b 1
