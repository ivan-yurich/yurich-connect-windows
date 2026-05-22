// package com.tecclub.flutter_singbox.ui.shared

// import android.app.Dialog
// import android.graphics.Bitmap
// import android.os.Bundle
// import android.view.LayoutInflater
// import android.widget.ImageView
// import androidx.appcompat.app.AlertDialog
// import androidx.fragment.app.DialogFragment
// import com.google.android.material.dialog.MaterialAlertDialogBuilder
// import com.tecclub.flutter_singbox.R

// class QRCodeDialog(private val bitmap: Bitmap) : DialogFragment() {
    
//     override fun onCreateDialog(savedInstanceState: Bundle?): Dialog {
//         val view = LayoutInflater.from(requireContext()).inflate(R.layout.dialog_qrcode, null)
//         val imageView = view.findViewById<ImageView>(R.id.qrcode_image)
//         imageView.setImageBitmap(bitmap)
        
//         return MaterialAlertDialogBuilder(requireContext())
//             .setView(view)
//             .setPositiveButton(android.R.string.ok, null)
//             .create()
//     }
// }