## **Cutover Playbook: Preventing Duplicates & Meeting Auditing Requirements**

### **Issue**
When sending emails from a shared mailbox, external recipients receive duplicate messages. This occurs because the client-side setting for saving sent items (DelegateSentItemsStyle) interacts with Exchange’s Cross-Server Submission feature, causing a second submission when certain message flags indicate the copy process is incomplete. The customer requires that sent items appear in the shared mailbox’s Sent Items folder for auditing, but current workarounds either break this requirement or introduce duplicates.

<img width="1524" height="895" alt="image" src="https://github.com/user-attachments/assets/4b4d9eab-7168-4f51-8bcb-c55fa3c0f2f7" />

### **Objective**

Ensure sent items appear in the shared mailbox’s Sent Items folder without creating duplicates during migration or configuration changes.

***

### **Step 1: Pre-Cutover Preparation**

*   **Inventory Shared Mailboxes**
    ```powershell
    Get-Mailbox -RecipientTypeDetails SharedMailbox | Select DisplayName, PrimarySmtpAddress, ServerName
    ```

*   **Decide Strategy**
    *   **Option 1:** Migrate shared mailbox to EXO.
    *   **Option 2:** Apply `Set-Mailbox` server-side settings.
    *   **Option 3:** Cached Mode mitigation (short-term).

*   **Communicate Changes**
    *   Inform users that Sent Items behavior will change.
    *   Explain that registry keys will no longer apply in New Outlook.

***

### **Step 2: Remove Risk Factors**

*   **Disable DelegateSentItemsStyle**
    *   Set to `0` or remove registry key via GPO:
            HKEY_CURRENT_USER\Software\Microsoft\Office\<version>\Outlook\Preferences
            DelegateSentItemsStyle = 0
*   **Confirm Cached Mode (if using Option 3)**
    *   Enable via Group Policy or Office 365 Admin templates.

***

### **Step 3: Apply Fix**

#### **Option 1: Migration to EXO**

*   Move mailbox using hybrid move request.
*   After migration:
    ```powershell
    Set-Mailbox <SharedMailboxName> -MessageCopyForSentAsEnabled $true -MessageCopyForSendOnBehalfEnabled $true
    ```
*   Validate with test sends from multiple clients.

#### **Option 2: Server-Side Settings (Hybrid or EXO)**

*   Apply:
    ```powershell
    Set-Mailbox <SharedMailboxName> -MessageCopyForSentAsEnabled $true -MessageCopyForSendOnBehalfEnabled $true
    ```
*   Audit:
    ```powershell
    Get-Mailbox <SharedMailboxName> | fl MessageCopyForSentAsEnabled, MessageCopyForSendOnBehalfEnabled
    ```
*   **Important:** Ensure DelegateSentItemsStyle=0 to avoid duplicate entries in shared mailbox Sent Items.

#### **Option 3: Cached Mode**

*   Enable Cached Mode for Classic Outlook users.
*   Combine with DelegateSentItemsStyle=0 to prevent duplicates.

***

### **Step 4: Validation**

*   Send test messages:
    *   From Classic Outlook (Cached Mode).
    *   From New Outlook (registry ignored).
*   Confirm:
    *   No duplicates for external recipients.
    *   Sent item appears in shared mailbox (or automation in place).

***

### **Step 5: Monitoring & Rollback**

*   Monitor message tracking logs for duplicate submissions.
*   If duplicates appear:
    *   Temporarily disable DelegateSentItemsStyle.
    *   Revert to sender-only copy until fix is confirmed.

***

### **Key Notes**

*   **New Outlook ignores registry keys** → rely on server-side settings.
*   **CSS rollback is not planned** → PG fix targeted for CY2025H2.
*   **Hybrid caveat:** Server-side copy may fail if shared mailbox remains on-prem and sender is in EXO.

***
### **References**

*  https://learn.microsoft.com/en-us/troubleshoot/exchange/user-and-shared-mailboxes/sent-mail-is-not-saved
*  MSFT Only - https://o365exchange.visualstudio.com/O365%20Core/_workitems/edit/5402087





