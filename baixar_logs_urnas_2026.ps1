<#
.SYNOPSIS
  Baixa os pacotes oficiais do TSE com os logs das urnas (Eleições 2026) e gera
  planilhas com a contagem de votos por hora de cada seção, lidas direto dos logs.

.DESCRIPTION
  Para cada UF (vários estados em paralelo):
    1. baixa "bu_imgbu_logjez_rdv_vscmr_2026_<turno>t_<UF>.zip" (retoma se cair);
    2. abre cada log de urna (*-log.jez) direto de dentro do pacote, sem extrair
       nada para o disco, e lê o arquivo logd.dat;
    3. conta cada linha "O voto do eleitor foi computado" do dia da eleição,
       separando por hora (horário de Brasília) e por tipo de habilitação
       (biométrica ou manual);
    4. grava:
         resumo_secoes_<UF>.csv   - uma linha por seção, com votos por hora
         votos_apos_17h_<UF>.csv  - cada voto computado a partir das 17h00 de Brasília
    5. apaga o .zip somente se a leitura deu certo (use -ManterZip para guardar).
  No final, junta tudo em resumo_secoes.csv e votos_apos_17h.csv.

  - Barra de progresso desativada (download mais rápido).
  - O computador não entra em suspensão enquanto o script roda.
  - Não precisa de 7-Zip.

  Opcional: -SalvarLogs guarda também cada log original (*-log.jez) em disco
  (~75 GB no 2º turno).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\baixar_logs_urnas_2026.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\baixar_logs_urnas_2026.ps1 -UFs RR,AC -Destino D:\TSE2026
#>

[CmdletBinding()]
param(
    [string]   $Destino   = 'C:\TSE2026',
    [ValidateSet(1,2)]
    [int]      $Turno     = 2,
    [string[]] $UFs       = @('AC','AL','AM','AP','BA','CE','DF','ES','GO','MA','MG','MS','MT','PA',
                              'PB','PE','PI','PR','RJ','RN','RO','RR','RS','SC','SE','SP','TO','ZZ'),
    [ValidateRange(1,8)]
    [int]      $Paralelo  = 3,
    [switch]   $ManterZip,
    [switch]   $SalvarLogs
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$BaseUrl = 'https://cdn.tse.jus.br/estatistica/sead/eleicoes/eleicoes2026/arqurnatot'
$DirZip  = Join-Path $Destino 'zips'
$DirOut  = Join-Path $Destino ("resultado_{0}t" -f $Turno)
$DirLogs = Join-Path $Destino ("logs_{0}t" -f $Turno)
$LogFile = Join-Path $Destino 'execucao.log'
$DiaEleicao = if ($Turno -eq 2) { '25/10/2026' } else { '04/10/2026' }

New-Item -ItemType Directory -Force -Path $DirZip, $DirOut | Out-Null
if ($SalvarLogs) { New-Item -ItemType Directory -Force -Path $DirLogs | Out-Null }

function Write-Log([string]$msg) {
    $linha = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Host $linha
    Add-Content -Path $LogFile -Value $linha -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Impede o computador de dormir
# ---------------------------------------------------------------------------
if (-not ('Win32.Power' -as [type])) {
Add-Type -Namespace Win32 -Name Power -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
"@
}
$ES_CONTINUOUS      = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1
function Set-NoSleep   { [void][Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) }
function Clear-NoSleep { [void][Win32.Power]::SetThreadExecutionState($ES_CONTINUOUS) }

$Curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
if (-not $Curl) { throw 'curl.exe não encontrado (vem com o Windows 10/11).' }

# ---------------------------------------------------------------------------
# Leitor de logs (C#, compilado na hora para ser rápido)
# ---------------------------------------------------------------------------
$CSharp = @"
using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Globalization;
using System.Text.RegularExpressions;

public static class UrnaLogScanner
{
    // Retorna: secoes_lidas;secoes_com_votos;votos_total;votos_apos_17h;erros
    public static string Scan(string zipPath, string uf, int offsetHoras, string dia,
                              string resumoPath, string detalhePath, string salvarDir)
    {
        int secoes = 0, comVotos = 0, erros = 0;
        long votosTotal = 0, votosApos17 = 0;
        Encoding latin = Encoding.GetEncoding(28591);
        CultureInfo ci = CultureInfo.InvariantCulture;
        DateTime corte17 = DateTime.ParseExact(dia + " 17:00:00", "dd/MM/yyyy HH:mm:ss", ci);

        using (var resumo = new StreamWriter(resumoPath, false, new UTF8Encoding(false)))
        using (var det = new StreamWriter(detalhePath, false, new UTF8Encoding(false)))
        using (var zip = ZipFile.OpenRead(zipPath))
        {
            var sb = new StringBuilder("uf;cd_municipio;zona;secao;arquivo;votos;votos_hab_manual;primeiro_voto_brt;ultimo_voto_brt");
            for (int h = 0; h < 24; h++) sb.Append(";h" + h.ToString("00"));
            resumo.WriteLine(sb.ToString());
            det.WriteLine("uf;cd_municipio;zona;secao;datahora_local;datahora_brasilia;habilitacao");

            foreach (ZipArchiveEntry e in zip.Entries)
            {
                // Nome: o<pleito 5><uf 2><municipio 5><zona 4><secao 4>-log.jez
                string nm = e.Name;
                if (!nm.EndsWith("-log.jez", StringComparison.OrdinalIgnoreCase)) continue;
                string b = nm.Substring(0, nm.Length - 8);
                if (b.Length < 21) continue;
                string mun = b.Substring(b.Length - 13, 5);
                int zona, sec;
                if (!int.TryParse(b.Substring(b.Length - 8, 4), out zona) || !int.TryParse(b.Substring(b.Length - 4, 4), out sec)) continue;
                secoes++;

                var ms = new MemoryStream();
                using (Stream s = e.Open()) s.CopyTo(ms);
                if (salvarDir != null && salvarDir.Length > 0)
                    File.WriteAllBytes(Path.Combine(salvarDir, e.Name), ms.ToArray());
                ms.Position = 0;

                int[] hrs = new int[24];
                int votos = 0, manuais = 0;
                DateTime primeiro = DateTime.MinValue, ultimo = DateTime.MinValue;
                string hab = "";
                try
                {
                    using (var inner = new ZipArchive(ms, ZipArchiveMode.Read))
                    {
                        foreach (ZipArchiveEntry ie in inner.Entries)
                        {
                            if (!ie.Name.Equals("logd.dat", StringComparison.OrdinalIgnoreCase)) continue;
                            using (var rd = new StreamReader(ie.Open(), latin))
                            {
                                string line;
                                while ((line = rd.ReadLine()) != null)
                                {
                                    if (line.Length < 20 || !line.StartsWith(dia, StringComparison.Ordinal)) continue;
                                    if (line.IndexOf("Tipo de habilita", StringComparison.Ordinal) >= 0)
                                    {
                                        hab = line.IndexOf("biom", StringComparison.OrdinalIgnoreCase) >= 0 ? "biometrica" : "manual";
                                        continue;
                                    }
                                    if (line.IndexOf("O voto do eleitor foi computado", StringComparison.Ordinal) < 0) continue;

                                    DateTime local = DateTime.ParseExact(line.Substring(0, 19), "dd/MM/yyyy HH:mm:ss", ci);
                                    DateTime brt = local.AddHours(offsetHoras);
                                    votos++;
                                    if (hab == "manual") manuais++;
                                    if (brt.Date == corte17.Date) hrs[brt.Hour]++;
                                    if (primeiro == DateTime.MinValue) primeiro = brt;
                                    ultimo = brt;
                                    if (brt >= corte17)
                                    {
                                        votosApos17++;
                                        det.WriteLine(uf + ";" + mun + ";" + zona + ";" + sec + ";" +
                                            local.ToString("yyyy-MM-dd HH:mm:ss", ci) + ";" +
                                            brt.ToString("yyyy-MM-dd HH:mm:ss", ci) + ";" + (hab.Length > 0 ? hab : "?"));
                                    }
                                    hab = "";
                                }
                            }
                        }
                    }
                }
                catch (Exception) { erros++; }

                if (votos > 0) comVotos++;
                votosTotal += votos;
                var row = new StringBuilder();
                row.Append(uf).Append(';').Append(mun).Append(';').Append(zona).Append(';').Append(sec).Append(';')
                   .Append(e.Name).Append(';').Append(votos).Append(';').Append(manuais).Append(';')
                   .Append(primeiro == DateTime.MinValue ? "" : primeiro.ToString("HH:mm:ss", ci)).Append(';')
                   .Append(ultimo == DateTime.MinValue ? "" : ultimo.ToString("HH:mm:ss", ci));
                for (int h = 0; h < 24; h++) row.Append(';').Append(hrs[h]);
                resumo.WriteLine(row.ToString());
            }
        }
        return secoes + ";" + comVotos + ";" + votosTotal + ";" + votosApos17 + ";" + erros;
    }
}
"@

# ---------------------------------------------------------------------------
# Trabalho de cada UF (roda em paralelo)
# ---------------------------------------------------------------------------
$JobUF = {
    param($Uf, $Url, $ZipPath, $Curl, $CSharp, $Offset, $Dia, $DirOut, $SalvarDir, $ManterZip)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference    = 'SilentlyContinue'
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    Add-Type -TypeDefinition $CSharp -ReferencedAssemblies System.IO.Compression, System.IO.Compression.FileSystem

    # tamanho esperado
    $esperado = 0
    $head = & $Curl -s -I -L $Url
    $cl = $head | Select-String -Pattern '^Content-Length:\s*(\d+)' | Select-Object -Last 1
    if ($cl) { $esperado = [int64]$cl.Matches[0].Groups[1].Value }

    $completo = (Test-Path $ZipPath) -and ($esperado -gt 0) -and ((Get-Item $ZipPath).Length -eq $esperado)
    $t0 = Get-Date
    if (-not $completo) {
        $ok = $false
        for ($t = 1; $t -le 20 -and -not $ok; $t++) {
            & $Curl -s -S -L --fail -C - --retry 5 --retry-delay 10 --connect-timeout 30 -o $ZipPath $Url 2>&1 | Out-Null
            $ok = ($LASTEXITCODE -eq 0) -and ((Get-Item $ZipPath).Length -eq $esperado -or $esperado -eq 0)
            if (-not $ok) { Start-Sleep -Seconds 15 }
        }
        if (-not $ok) { throw "Falha no download de $Url" }
    }
    $tDown = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)

    $t1 = Get-Date
    $salvar = ''
    if ($SalvarDir) { $salvar = Join-Path $SalvarDir $Uf; New-Item -ItemType Directory -Force -Path $salvar | Out-Null }
    $res = [UrnaLogScanner]::Scan($ZipPath, $Uf, $Offset, $Dia,
                                  (Join-Path $DirOut "resumo_secoes_$Uf.csv"),
                                  (Join-Path $DirOut "votos_apos_17h_$Uf.csv"), $salvar)
    $tScan = [math]::Round(((Get-Date) - $t1).TotalMinutes, 1)
    $p = $res.Split(';')
    if ([int]$p[0] -gt 0 -and -not $ManterZip) { Remove-Item $ZipPath -Force }
    "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f $Uf, $p[0], $p[1], $p[2], $p[3], $p[4], $tDown, $tScan
}

# Diferença para o horário de Brasília (a urna grava o horário local)
$Offsets = @{ AC = 2; AM = 1; RR = 1; RO = 1; MT = 1; MS = 1 }

# ---------------------------------------------------------------------------
# Execução
# ---------------------------------------------------------------------------
$inicio = Get-Date
Set-NoSleep
Write-Log ("Início. Turno {0} ({1}). UFs: {2}. Destino: {3}" -f $Turno, $DiaEleicao, ($UFs -join ','), $Destino)

try {
    $fila = New-Object System.Collections.Queue
    foreach ($uf in $UFs) {
        if (Test-Path (Join-Path $DirOut ".ok_$uf")) { Write-Log "${uf}: já processado, pulando."; continue }
        $fila.Enqueue($uf)
    }
    $jobs = @{}
    while ($fila.Count -gt 0 -or $jobs.Count -gt 0) {
        Set-NoSleep
        while ($fila.Count -gt 0 -and $jobs.Count -lt $Paralelo) {
            $uf   = $fila.Dequeue()
            $nome = "bu_imgbu_logjez_rdv_vscmr_2026_${Turno}t_$uf.zip"
            $off  = if ($Offsets.ContainsKey($uf)) { $Offsets[$uf] } else { 0 }
            $sd   = if ($SalvarLogs) { $DirLogs } else { '' }
            Write-Log "${uf}: baixando e lendo $nome ..."
            $jobs[$uf] = Start-Job -ScriptBlock $JobUF -ArgumentList $uf, "$BaseUrl/$nome", (Join-Path $DirZip $nome),
                         $Curl, $CSharp, $off, $DiaEleicao, $DirOut, $sd, [bool]$ManterZip
        }
        foreach ($uf in @($jobs.Keys)) {
            $j = $jobs[$uf]
            if ($j.State -notin 'Completed','Failed','Stopped') { continue }
            try {
                $out = Receive-Job $j -ErrorAction Stop | Select-Object -Last 1
                $p = $out.Split('|')
                Write-Log ("{0}: {1} seções lidas, {2} com votos, {3} votos, {4} a partir das 17h (Brasília), {5} logs com erro. Download {6} min, leitura {7} min." -f $p[0],$p[1],$p[2],$p[3],$p[4],$p[5],$p[6],$p[7])
                if ([int]$p[1] -gt 0) { New-Item -ItemType File -Force -Path (Join-Path $DirOut ".ok_$uf") | Out-Null }
                else { Write-Log "${uf}: ATENÇÃO - nenhuma seção lida. O .zip foi mantido em $DirZip." }
            } catch {
                Write-Log "${uf}: ERRO - $($_.Exception.Message)"
            }
            Remove-Job $j -Force
            $jobs.Remove($uf)
        }
        Start-Sleep -Seconds 5
    }

    # Junta os arquivos de todas as UFs
    foreach ($tipo in 'resumo_secoes', 'votos_apos_17h') {
        $final = Join-Path $DirOut "$tipo.csv"
        $partes = Get-ChildItem $DirOut -Filter "${tipo}_*.csv" | Sort-Object Name
        if (-not $partes) { continue }
        $w = New-Object System.IO.StreamWriter($final, $false, (New-Object System.Text.UTF8Encoding($false)))
        try {
            $primeiro = $true
            foreach ($f in $partes) {
                $r = New-Object System.IO.StreamReader($f.FullName)
                try {
                    $cab = $r.ReadLine()
                    if ($primeiro) { $w.WriteLine($cab); $primeiro = $false }
                    while (($l = $r.ReadLine()) -ne $null) { $w.WriteLine($l) }
                } finally { $r.Dispose() }
            }
        } finally { $w.Dispose() }
        Write-Log "Arquivo final: $final"
    }
}
finally {
    Get-Job | Where-Object { $_.State -eq 'Running' } | Stop-Job -ErrorAction SilentlyContinue
    Clear-NoSleep
    Write-Log ("Fim. Duração: {0:hh\:mm\:ss}. Resultados em {1}" -f ((Get-Date) - $inicio), $DirOut)
}
