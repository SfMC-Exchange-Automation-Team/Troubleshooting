@{
    PackageVersion = '1.0.1'
    Article = 'https://support.microsoft.com/en-us/servicing/exchange/server/update/2026/5130098'
    GuidanceReviewed = '2026-09-25'
    ExchangeVersion = '15.2.2562.49'
    Dll = @{
        Name = 'korwbrkr.dll'
        Version = '16.0.5194.1000'
        Bytes = 326544
        SHA256 = '1C6BD8E144BA677EBCC83323AE59DB3881918170F9B3A5189B44611558B92C61'
    }
    Rules = @(
        @{
            Name = 'ko.token.rule.bin'
            Bytes = 56132
            SHA256 = '8F2BD853593913EB8F73DCD4FCAC4216F216A0FF76A4569DF071BE3C36773010'
        }
        @{
            Name = 'ko.complex.rule.bin'
            Bytes = 717792
            SHA256 = '0390D1E9A76EF33283025CF8F164430E311584B9535949C4EA1A74B6BB107B87'
        }
    )
    SqlPackage = @{
        Name = 'SQLEXPR_x64_ENU.exe'
        Version = '17.0.1000.7'
        Bytes = 748772024
        SHA256 = '74AA90C11202A5524E769B9BC22531BAEF22D91E9B2D2E8C3CB99E89A65C5297'
        Url = 'https://download.microsoft.com/download/dea8c210-c44a-4a9d-9d80-0c81578860c5/ENU/SQLEXPR_x64_ENU.exe'
    }
}
