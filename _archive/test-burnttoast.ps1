Import-Module BurntToast

# Test 1: Basic Toast
Write-Host "Testing basic notification..." -ForegroundColor Cyan
New-BurntToastNotification -Text 'Test', 'Basic notification works'

# Test 2: Interactive Toast
Write-Host "Testing interactive notification..." -ForegroundColor Cyan
$btn = New-BTButton -Content 'Click Me' -Arguments 'claude-runner:focus?button=1' -ActivationType Protocol
New-BurntToastNotification -Text 'Test', 'Interactive notification' -Button $btn
Write-Host "Notifications sent. Please check if they appeared and if the button works." -ForegroundColor Green
