codeunit 50101 "BCL Install"
{
    Subtype = Install;

    trigger OnInstallAppPerCompany()
    begin
        RegisterWebService();
    end;

    local procedure RegisterWebService()
    var
        TenantWebService: Record "Tenant Web Service";
    begin
        if TenantWebService.Get(TenantWebService."Object Type"::Codeunit, ServiceNameTok) then
            exit;

        TenantWebService.Init();
        TenantWebService."Object Type" := TenantWebService."Object Type"::Codeunit;
        TenantWebService."Service Name" := ServiceNameTok;
        TenantWebService."Object ID" := Codeunit::"BCL Sales Smoke";
        TenantWebService.Published := true;
        TenantWebService.Insert(true);
    end;

    var
        ServiceNameTok: Label 'BCLSalesSmoke', Locked = true;
}
