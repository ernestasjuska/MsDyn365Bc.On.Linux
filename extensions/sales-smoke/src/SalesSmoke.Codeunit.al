codeunit 50100 "BCL Sales Smoke"
{
    /// <summary>
    /// Creates a customer, a service item and a one-line sales order, then
    /// ships and invoices it. Returns the posted sales invoice number.
    /// Reachable as an OData V4 unbound action once "BCL Install" has
    /// registered this codeunit as a tenant web service.
    /// </summary>
    [ServiceEnabled]
    procedure CreateAndPostSalesOrder(): Text
    var
        SalesHeader: Record "Sales Header";
        SalesInvoiceHeader: Record "Sales Invoice Header";
        OrderNo: Code[20];
        CustomerNo: Code[20];
        ItemNo: Code[20];
    begin
        CustomerNo := CreateCustomer();
        ItemNo := CreateServiceItem();
        OrderNo := CreateOrder(CustomerNo, ItemNo);

        SalesHeader.Get(SalesHeader."Document Type"::Order, OrderNo);
        SalesHeader.Ship := true;
        SalesHeader.Invoice := true;
        Codeunit.Run(Codeunit::"Sales-Post", SalesHeader);

        SalesInvoiceHeader.SetRange("Order No.", OrderNo);
        if not SalesInvoiceHeader.FindLast() then
            Error('Sales order %1 posted but no sales invoice header was found for it.', OrderNo);

        exit(SalesInvoiceHeader."No.");
    end;

    local procedure CreateCustomer(): Code[20]
    var
        Customer: Record Customer;
        TemplateCustomer: Record Customer;
    begin
        // Posting groups are localization-specific, so copy them off an
        // existing demo customer rather than hardcoding CRONUS W1 codes.
        TemplateCustomer.SetFilter("Gen. Bus. Posting Group", '<>%1', '');
        TemplateCustomer.SetFilter("Customer Posting Group", '<>%1', '');
        if not TemplateCustomer.FindFirst() then
            Error('No demo customer with posting groups exists to copy from.');

        Customer.Init();
        Customer.Insert(true);
        Customer.Validate(Name, 'BCL Smoke Customer');
        Customer.Validate("Gen. Bus. Posting Group", TemplateCustomer."Gen. Bus. Posting Group");
        Customer.Validate("VAT Bus. Posting Group", TemplateCustomer."VAT Bus. Posting Group");
        Customer.Validate("Customer Posting Group", TemplateCustomer."Customer Posting Group");
        Customer.Modify(true);
        exit(Customer."No.");
    end;

    local procedure CreateServiceItem(): Code[20]
    var
        Item: Record Item;
        TemplateItem: Record Item;
    begin
        // Type::Service keeps the posting off the item ledger, so no
        // inventory, location or warehouse setup is required.
        TemplateItem.SetFilter("Gen. Prod. Posting Group", '<>%1', '');
        TemplateItem.SetFilter("VAT Prod. Posting Group", '<>%1', '');
        if not TemplateItem.FindFirst() then
            Error('No demo item with posting groups exists to copy from.');

        Item.Init();
        Item.Insert(true);
        Item.Validate(Description, 'BCL Smoke Service');
        Item.Validate(Type, Item.Type::Service);
        Item.Validate("Gen. Prod. Posting Group", TemplateItem."Gen. Prod. Posting Group");
        Item.Validate("VAT Prod. Posting Group", TemplateItem."VAT Prod. Posting Group");
        Item.Validate("Base Unit of Measure", TemplateItem."Base Unit of Measure");
        Item.Validate("Unit Price", 100);
        Item.Modify(true);
        exit(Item."No.");
    end;

    local procedure CreateOrder(CustomerNo: Code[20]; ItemNo: Code[20]): Code[20]
    var
        SalesHeader: Record "Sales Header";
        SalesLine: Record "Sales Line";
    begin
        SalesHeader.Init();
        SalesHeader.Validate("Document Type", SalesHeader."Document Type"::Order);
        SalesHeader.Insert(true);
        SalesHeader.Validate("Sell-to Customer No.", CustomerNo);
        SalesHeader.Modify(true);

        SalesLine.Init();
        SalesLine.Validate("Document Type", SalesHeader."Document Type");
        SalesLine.Validate("Document No.", SalesHeader."No.");
        SalesLine.Validate("Line No.", 10000);
        SalesLine.Insert(true);
        SalesLine.Validate(Type, SalesLine.Type::Item);
        SalesLine.Validate("No.", ItemNo);
        SalesLine.Validate(Quantity, 5);
        SalesLine.Modify(true);

        exit(SalesHeader."No.");
    end;
}
