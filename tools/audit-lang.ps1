param([string]$Dir, [string]$Json)
# Independent audit of lang.json against SalamatYar.ps1
if (-not $Json) { $Json = Join-Path $Dir 'lang.json' }
$ps = [IO.File]::ReadAllText((Join-Path $Dir 'SalamatYar.ps1'), [Text.Encoding]::UTF8)
$j = [IO.File]::ReadAllText($Json, [Text.Encoding]::UTF8) | ConvertFrom-Json
$order = @($j._order)
$issues = New-Object Collections.ArrayList
$keys = @{}
foreach ($p in $j.strings.PSObject.Properties) { $keys[$p.Name] = @($p.Value) }

$used = @{}
foreach ($m in [regex]::Matches($ps, '\[\[(\w+)\]\]')) { $used[$m.Groups[1].Value] = $true }
foreach ($m in [regex]::Matches($ps, "\bT '(\w+)'")) { $used[$m.Groups[1].Value] = $true }

foreach ($k in $used.Keys) { if (-not $keys.ContainsKey($k)) { [void]$issues.Add("USED-BUT-MISSING: $k") } }
foreach ($k in $keys.Keys) { if (-not $used.ContainsKey($k)) { [void]$issues.Add("UNUSED: $k") } }

$latinOk = 'appName', 'authorName', 'g3s'
foreach ($k in $keys.Keys) {
    $v = $keys[$k]
    if ($v.Count -ne $order.Count) { [void]$issues.Add("COUNT: $k has $($v.Count)"); continue }
    $ph0 = ([regex]::Matches([string]$v[0], '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object) -join ''
    for ($i = 0; $i -lt $v.Count; $i++) {
        $s = [string]$v[$i]; $lg = $order[$i]
        if ($s.Trim().Length -eq 0) { [void]$issues.Add("EMPTY: $k/$lg") ; continue }
        if ($s -match '[&<>"]') { [void]$issues.Add("FORBIDDEN-CHAR: $k/$lg") }
        $ph = ([regex]::Matches($s, '\{\d\}') | ForEach-Object { $_.Value } | Sort-Object) -join ''
        if ($ph -ne $ph0) { [void]$issues.Add("PLACEHOLDER: $k/$lg '$ph' vs '$ph0'") }
        if ($lg -in 'en', 'ru', 'zh' -and $s -match '[؀-ۿ]') { [void]$issues.Add("ARABIC-SCRIPT-IN-$lg`: $k") }
        if ($lg -eq 'ar' -and $s -match '[پچژگکی۰-۹]') { [void]$issues.Add("PERSIAN-LETTER-IN-ar: $k") }
        if ($latinOk -notcontains $k) {
            if ($lg -eq 'ru' -and $s -notmatch '[Ѐ-ӿ]') { [void]$issues.Add("NO-CYRILLIC: $k") }
            if ($lg -eq 'zh' -and $s -notmatch '[一-鿿]') { [void]$issues.Add("NO-CJK: $k") }
            if ($lg -eq 'ar' -and $s -notmatch '[؀-ۿ]') { [void]$issues.Add("NO-ARABIC: $k") }
            if ($lg -eq 'en' -and $s -notmatch '[A-Za-z]') { [void]$issues.Add("NO-LATIN: $k") }
            if ($i -gt 0 -and $lg -ne 'ar' -and $s -eq [string]$v[0]) { [void]$issues.Add("SAME-AS-FA: $k/$lg") }
        }
    }
}
"keys=$($keys.Count) used=$($used.Count) issues=$($issues.Count)"
$issues | Sort-Object
