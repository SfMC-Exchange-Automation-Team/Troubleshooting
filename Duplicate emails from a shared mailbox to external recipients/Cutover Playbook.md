# **Cutover Playbook: Resolving issues with duplicate emails from a shared mailbox to external recipients**

<img width="1534" height="900" alt="image" src="https://github.com/user-attachments/assets/866c4fa6-bcb3-4131-8070-3eb336819320" />


### **Issue**

When sending emails from a shared mailbox, external recipients receive duplicate messages. This occurs because the client-side setting for saving sent items (`DelegateSentItemsStyle`) interacts with Exchange’s Cross-Server Submission feature, causing a second submission when certain message flags indicate the copy process is incomplete.  
The customer requires that sent items appear in the shared mailbox’s **Sent Items** folder for auditing, but current workarounds either break this requirement or introduce duplicates.

***

### **Objective**

Ensure sent items appear in the shared mailbox’s **Sent Items** folder without creating duplicates during migration or configuration changes.

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

### **Step 2: Remove Risk Factors (After Confirmation)**

*   **Important Change:**  
    **Do not remove DelegateSentItemsStyle until you confirm that `Set-Mailbox` settings are active.**  
    Receiving duplicates is better than missing sent items for auditing.
*   **Registry Key Location:**
        HKEY_CURRENT_USER\Software\Microsoft\Office\<version>\Outlook\Preferences
        DelegateSentItemsStyle = 0
*   **Cached Mode (if using Option 3):**  
    Enable via Group Policy or Office 365 Admin templates.

***

### **Step 3: Apply Fix**

#### **Option 1: Migration to EXO**

*   Move mailbox using hybrid move request.
*   After migration:
    ```powershell
    Set-Mailbox <SharedMailboxName> -MessageCopyForSentAsEnabled $true -MessageCopyForSendOnBehalfEnabled $true
    ```
*   **Validate before registry removal:**
    ```powershell
    Get-Mailbox <SharedMailboxName> | fl MessageCopyForSentAsEnabled, MessageCopyForSendOnBehalfEnabled
    ```
*   Confirm both properties are `True` before removing DelegateSentItemsStyle.

***

#### **Option 2: Server-Side Settings (Hybrid or EXO)**

*   Apply:
    ```powershell
    Set-Mailbox <SharedMailboxName> -MessageCopyForSentAsEnabled $true -MessageCopyForSendOnBehalfEnabled $true
    ```
*   Audit:
    ```powershell
    Get-Mailbox <SharedMailboxName> | fl MessageCopyForSentAsEnabled, MessageCopyForSendOnBehalfEnabled
    ```
*   **Critical:**  
    Only after successful confirmation remove DelegateSentItemsStyle.  
    If confirmation fails, keep client-side setting to ensure copies exist (duplicates acceptable short-term).

***

#### **Option 3: Cached Mode**

*   Enable Cached Mode for Classic Outlook users.
*   Combine with DelegateSentItemsStyle=0 **after confirmation of server-side copy**.

***

### **Step 4: Validation**

*   Send test messages:
    *   From Classic Outlook (Cached Mode).
    *   From New Outlook (registry ignored).
*   Confirm:
    *   Sent item appears in shared mailbox.
    *   External recipients do not receive duplicates (or duplicates are acceptable until registry removal).

***

### **Step 5: Monitoring & Rollback**

*   Monitor message tracking logs for duplicate submissions.
*   If duplicates persist after registry removal:
    *   Re-check server-side settings.
    *   Consider temporary rollback of registry key only if server-side copy is stable.

***

### **Key Notes**

*   **New Outlook ignores registry keys** → rely on server-side settings.
*   **Do not remove DelegateSentItemsStyle until `Set-Mailbox` success is verified.**
*   **Hybrid caveat:** Server-side copy may fail if shared mailbox remains on-prem and sender is in EXO.
*   **CSS rollback is not planned** → PG fix targeted for CY2025H2.

***

### **References**

*   <https://learn.microsoft.com/en-us/troubleshoot/exchange/user-and-shared-mailboxes/sent-mail-is-not-saved>
*   MSFT Only: <https://o365exchange.visualstudio.com/O365%20Core/_workitems/edit/5402087>
